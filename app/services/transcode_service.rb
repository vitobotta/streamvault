# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"

# Remuxes/transcodes streams via FFmpeg for browser playback.
# Browser-safe H.264 video is copied when possible; risky/unsupported
# video, UHD video, and streams with burned-in subtitles are normalized
# to 1080p H.264. Audio is always transcoded to AAC.
#
# The ffmpeg child runs in its own process group so the entire group
# (ffmpeg + any helper processes) can be killed when the client
# disconnects — preventing orphaned processes on page refresh/navigation.
#
# stderr is drained in a background thread (preventing pipe-buffer
# deadlock) and captured so that failures are surfaced: if ffmpeg exits
# before producing any output (bad URL, auth failure, expired link), a
# TranscodeError is raised with the ffmpeg diagnostic, letting the
# controller return a meaningful error instead of an empty 200 that
# leaves the browser spinner spinning forever.
class TranscodeService
  FFMPEG_PATH = "ffmpeg"
  FFPROBE_PATH = "ffprobe"
  FMP4_FLAGS = "+frag_keyframe+empty_moov+default_base_moof"
  # Maximum bytes of stderr to include in error messages.
  STDERR_MAX_BYTES = 4096
  # HLS segment duration in seconds — balances latency against overhead.
  # 4s (up from 2s) gives iOS Safari a deeper natural buffer per
  # segment, reducing the periodic black-screen underruns that happen
  # when the transcode throughput dips between segment writes.  Fewer
  # segment requests also means less playlist re-fetching overhead.
  HLS_SEGMENT_DURATION = 4
  # HLS flags: temp_file writes segments via a .tmp~ sidecar and renames
  # them only once complete, so clients never read a partial segment.
  HLS_FLAGS = "temp_file".freeze
  # How long to wait for ffmpeg to emit the first segment before giving up.
  FIRST_SEGMENT_TIMEOUT_SECONDS = 30
  SHUTDOWN_GRACE_SECONDS = 1
  FIRST_DATA_TIMEOUT_SECONDS = 30
  STREAM_CHUNK_BYTES = 131_072
  STREAM_QUEUE_MAX_BYTES = 32 * 1024 * 1024
  STREAM_QUEUE_MAX_CHUNKS = STREAM_QUEUE_MAX_BYTES / STREAM_CHUNK_BYTES
  KEYFRAME_INTERVAL_SECONDS = 2
  HLS_READ_RATE = "1.0"
  HLS_INITIAL_BURST_SECONDS = 30
  REMUX_KEYFRAME_PROBE_TIMEOUT_SECONDS = 10
  MAX_REMUX_PREROLL_SECONDS = 120
  # No mid-stream idle timeout: ffmpeg produces data in bursts, and
  # pausing between bursts is normal. The frontend watchdog detects
  # true playback stalls (video element buffer ran dry) — the backend
  # cannot distinguish a transcoding pause from a real stall.
  MIN_VALID_DURATION_SECONDS = 60
  MAX_VALID_DURATION_SECONDS = 24 * 60 * 60
  MAX_STREAM_INDEX = 200
  SUBTITLE_EXTRACTION_TIMEOUT_SECONDS = 45
  # Representative remote Real-Debrid files can need more than 12 seconds
  # to seek a sparse subtitle stream. A timeout is a retryable extraction
  # failure, not proof that the requested window contains no cues.
  SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS = 30
  SUBTITLE_EXTRACTION_WINDOW_SECONDS = 15
  MIN_SUBTITLE_EXTRACTION_WINDOW_SECONDS = 5
  MAX_SUBTITLE_EXTRACTION_WINDOW_SECONDS = 60
  SUBTITLE_FALLBACK_DURATION_SECONDS = 4
  MAX_COPY_VIDEO_WIDTH = 1920
  MAX_COPY_VIDEO_HEIGHT = 1080
  SAFE_VIDEO_FILTER =
    "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p"
  # Keep the audio clock locked to its timestamps.  Values greater than 1
  # allow soft sample-rate compensation (up to this many samples/second),
  # while first_pts=0 pads or trims the beginning onto the same zero-based
  # timeline as video.
  AUDIO_SYNC_FILTER = "aresample=async=1000:first_pts=0"
  VIDEO_TRANSCODE_ARGS = [
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-crf", "23",
    "-profile:v", "high",
    "-pix_fmt", "yuv420p",
    # Use all available CPU cores for encoding — critical on production
    # servers without hardware acceleration.  Without this, libx264
    # defaults to 1 thread and leaves most cores idle.
    "-threads", "auto",
    # No B-frames: MSE's fMP4 chunk demuxer requires each fragment to start
    # with a random access point (I-frame).  With B-frames, +frag_keyframe
    # fragments at keyframes in display order but the first packet by DTS
    # is a B-frame → CHUNK_DEMUXER_ERROR_APPEND_FAILED.
    "-bf", "0"
  ].freeze
  VIDEOTOOLBOX_TRANSCODE_ARGS = [
    "-c:v", "h264_videotoolbox",
    "-b:v", "4000k",
    "-pix_fmt", "yuv420p",
    "-bf", "0"
  ].freeze
  SAFE_H264_PIXEL_FORMATS = %w[yuv420p].freeze
  TEXT_SUBTITLE_CODECS = %w[subrip ass ssa webvtt mov_text].freeze
  PARTIAL_SUBTITLE_TITLE_PATTERN = /\b(forced|signs?|signs?\s*(?:&|and)?\s*songs?|songs?\s*(?:&|and)?\s*signs?|lyrics?|karaoke|commentary|comment)\b/i
  HEARING_IMPAIRED_TITLE_PATTERN = /\b(sdh|cc|closed captions?|hearing impaired|hi)\b/i
  LANGUAGE_ALIASES = {
    "ENG" => %w[eng en english],
    "FRENCH" => %w[fre fra fr french],
    "GERMAN" => %w[ger deu de german],
    "SPANISH" => %w[spa es spanish castellano],
    "ITALIAN" => %w[ita it italian],
    "JAPANESE" => %w[jpn ja japanese],
    "KOREAN" => %w[kor ko korean],
    "CHINESE" => %w[chi zho zh cmn chinese],
    "HINDI" => %w[hin hi hindi],
    "ARABIC" => %w[ara ar arabic],
    "PORTUGUESE" => %w[por pt ptbr portuguese brazilian],
    "RUSSIAN" => %w[rus ru russian],
    "DUTCH" => %w[dut nld nl dutch],
    "POLISH" => %w[pol pl polish],
    "TURKISH" => %w[tur tr turkish],
    "SWEDISH" => %w[swe sv swedish]
  }.freeze
  # Cache probe results to avoid repeated ffprobe round-trips for the same URL.
  # Key: input_url, Value: { duration:, video_stream:, expires_at: }
  @probe_cache = {}
  PROBE_CACHE_TTL = 600 # 10 minutes — repeated seeks to the same URL
  # (common during a viewing session) should hit cache, not re-probe.
  PROBE_CACHE_MAX_SIZE = 500 # 500 entries across all users/content

  class TranscodeError < StandardError; end

  # Owns the diagnostic resources that must remain alive for the full
  # lifetime of a non-blocking HLS ffmpeg process.
  class HlsProcess
    attr_reader :pid

    def initialize(pid:, stderr_io:, stderr_thread:, stderr_buffer:, stderr_mutex:)
      @pid = pid
      @stderr_io = stderr_io
      @stderr_thread = stderr_thread
      @stderr_buffer = stderr_buffer
      @stderr_mutex = stderr_mutex
    end

    def diagnostic
      @stderr_mutex.synchronize { @stderr_buffer.dup }
    end

    def close_diagnostics
      finished = @stderr_thread.join(1)
      @stderr_io.close unless @stderr_io.closed?
      @stderr_thread.join(1) unless finished
    rescue IOError, Errno::EBADF
      @stderr_thread.join(1)
    end
  end

  CommandCaptureResult = Struct.new(:stdout, :stderr, :status, :timed_out, keyword_init: true)

  SubtitleExtractionResult = Struct.new(:status, :vtt, :cue_count, :source, :diagnostic, keyword_init: true) do
    def ok?
      status == :ok
    end

    def empty_window?
      status == :empty_window
    end
  end


  # Stream transcoded/remuxed fMP4 from FFmpeg.
  # Copies video only when the source is already browser-safe H.264 at
  # 1080p or below. UHD/HEVC/remux sources are transcoded so the browser
  # is not asked to decode crash-prone streams directly.
  #
  # Accepts optional headers hash, start_seconds for seeking, and audio
  # language/stream hints for choosing the source audio track before playback.
  #
  # Raises TranscodeError if ffmpeg exits before producing any output
  # (bad URL, auth failure, expired link).  When the caller stops reading
  # (client disconnect → exception propagates through the yield), the
  # ensure block kills ffmpeg.
  def self.transcode_to_fmp4(input_url, headers: {}, start_seconds: 0, audio_stream: nil, subtitle_stream: nil, default_language: nil, preferred_languages: [], remux: false, telemetry_id: nil, &block)
    cmd = build_ffmpeg_command(
      input_url,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages,
      remux: remux,
      telemetry_id: telemetry_id
    )

    transcode_to_fmp4_internal(cmd, telemetry_id: telemetry_id, &block)
  end

  # Transcode to HLS segments on disk for iOS Safari playback.
  #
  # The returned HlsProcess owns the stderr pipe and drain thread.  The
  # caller must retain it until ffmpeg exits or the session is stopped;
  # closing the reader while ffmpeg is alive would leave stderr attached
  # to a readerless pipe and can terminate ffmpeg on its next diagnostic.
  def self.transcode_to_hls(input_url, segment_dir:, headers: {}, start_seconds: 0, audio_stream: nil, subtitle_stream: nil, default_language: nil, preferred_languages: [], wait_for_first_segment: true, telemetry_id: nil)
    FileUtils.mkdir_p(segment_dir)

    cmd = build_ffmpeg_command(
      input_url,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages,
      output_spec: :hls,
      segment_dir: segment_dir,
      telemetry_id: telemetry_id
    )

    err_rd, err_wr = IO.pipe
    pid = Process.spawn(*cmd, in: "/dev/null", out: "/dev/null", err: err_wr, pgroup: true)
    err_wr.close

    stderr_buf = +""
    stderr_mutex = Mutex.new
    stderr_thread = Thread.new do
      loop do
        chunk = err_rd.readpartial(4096)
        stderr_mutex.synchronize do
          stderr_buf << chunk
          stderr_buf.replace(stderr_buf.byteslice(-STDERR_MAX_BYTES, STDERR_MAX_BYTES)) if stderr_buf.bytesize > STDERR_MAX_BYTES
        end
      end
    rescue EOFError, IOError, Errno::EBADF
    end
    process = HlsProcess.new(
      pid: pid,
      stderr_io: err_rd,
      stderr_thread: stderr_thread,
      stderr_buffer: stderr_buf,
      stderr_mutex: stderr_mutex
    )

    return process unless wait_for_first_segment

    playlist_path = File.join(segment_dir, "playlist.m3u8")
    begin
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FIRST_SEGMENT_TIMEOUT_SECONDS

      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        if status
          process.close_diagnostics
          if status.success? && File.exist?(playlist_path) && Dir.glob(File.join(segment_dir, "*.ts")).any?
            break
          end

          raise TranscodeError,
            "FFmpeg exited (status #{status.exitstatus}) without producing segments. #{stderr_summary(process.diagnostic)}"
        end

        break if File.exist?(playlist_path) && Dir.glob(File.join(segment_dir, "*.ts")).any?

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise TranscodeError,
            "FFmpeg timed out after #{FIRST_SEGMENT_TIMEOUT_SECONDS}s waiting for first segment. #{stderr_summary(process.diagnostic)}"
        end

        sleep 0.1
      end
    rescue TranscodeError
      kill_process_group(pid)
      process.close_diagnostics
      raise
    end

    process
  end

  # Spawns a subprocess from the given command array and streams stdout
  # through a bounded in-memory queue.  Backpressure propagates to ffmpeg
  # once the queue reaches STREAM_QUEUE_MAX_BYTES; unlike the previous
  # Tempfile spool, consumed bytes do not accumulate on disk for the full
  # duration of every movie.
  def self.transcode_to_fmp4_internal(cmd, telemetry_id: nil, &block)
    rd, wr = IO.pipe
    err_rd, err_wr = IO.pipe
    pid = Process.spawn(*cmd, in: "/dev/null", out: wr, err: err_wr, pgroup: true)
    wr.close
    err_wr.close

    stderr_buf = +""
    stderr_mutex = Mutex.new
    stderr_thread = Thread.new do
      loop do
        chunk = err_rd.readpartial(4096)
        stderr_mutex.synchronize do
          stderr_buf << chunk
          stderr_buf.replace(stderr_buf.byteslice(-STDERR_MAX_BYTES, STDERR_MAX_BYTES)) if stderr_buf.bytesize > STDERR_MAX_BYTES
        end
      end
    rescue EOFError, IOError, Errno::EBADF
    end

    chunks = SizedQueue.new(STREAM_QUEUE_MAX_CHUNKS)
    reader_error = nil
    reader_thread = Thread.new do
      begin
        loop { chunks.push(rd.readpartial(STREAM_CHUNK_BYTES)) }
      rescue EOFError
      rescue ClosedQueueError, IOError, Errno::EBADF
      rescue StandardError => e
        reader_error = e
      ensure
        chunks.close
      end
    end

    begin
      total_bytes = 0
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = start_time + FIRST_DATA_TIMEOUT_SECONDS
      first_chunk = nil

      loop do
        begin
          first_chunk = chunks.pop(true)
        rescue ThreadError
          # Queue is temporarily empty while ffmpeg is still starting.
        end
        break if first_chunk

        if chunks.closed?
          diagnostic = stderr_mutex.synchronize { stderr_buf.dup }
          if reader_error
            raise TranscodeError, "FFmpeg output reader failed: #{reader_error.message}. #{stderr_summary(diagnostic)}"
          end
          raise TranscodeError, "FFmpeg exited without producing output. #{stderr_summary(diagnostic)}"
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          diagnostic = stderr_mutex.synchronize { stderr_buf.dup }
          raise TranscodeError,
            "FFmpeg timed out after #{FIRST_DATA_TIMEOUT_SECONDS}s waiting for first data. #{stderr_summary(diagnostic)}"
        end
        sleep 0.05
      end

      chunk = first_chunk
      while chunk
        yield chunk
        total_bytes += chunk.bytesize
        chunk = chunks.pop
      end

      if reader_error
        diagnostic = stderr_mutex.synchronize { stderr_buf.dup }
        raise TranscodeError, "FFmpeg output reader failed: #{reader_error.message}. #{stderr_summary(diagnostic)}"
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      rate_kbps = elapsed.positive? ? (total_bytes * 8 / 1000.0 / elapsed).round : 0
      if defined?(Rails)
        id = sanitize_telemetry_id(telemetry_id)
        Rails.logger.info("[Transcode] playback_id=#{id} ffmpeg_finished bytes=#{total_bytes} elapsed=#{elapsed.round(1)}s rate_kbps=#{rate_kbps}")
      end
    ensure
      chunks.close
      reader_thread.kill
      reader_thread.join(1)
      kill_process_group(pid)
      stderr_thread.kill
      stderr_thread.join(1)
      rd.close
      err_rd.close
    end
  end
  private_class_method :transcode_to_fmp4_internal

  # Probe the duration of a stream URL using ffprobe.
  # Returns the duration in seconds (float), or 0 if it can't be determined.
  # Uses the probe cache to avoid repeated ffprobe calls for the same URL.
  # This is called by the player via AJAX (/transcode/duration) — it's
  # non-blocking, the video plays while the probe runs in the background.
  def self.probe_duration(input_url, headers: {})
    cached = cache_get(input_url)
    return cached[:duration] if cached && cached[:duration]

    header_str = ffmpeg_headers(headers)

    cmd = [ FFPROBE_PATH, "-v", "error" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    cmd += [ "-show_entries", "format=duration:stream=duration:format_tags=DURATION:stream_tags=DURATION",
            "-of", "json",
            input_url ]

    result = capture_command(cmd, timeout_seconds: 10)
    return 0 if result.timed_out || !result.status&.success?

    duration = extract_probe_duration(result.stdout)
    cache_store(input_url, duration: duration)
    duration
  rescue StandardError
    0
  end

  def self.probe_media_tracks(input_url, headers: {})
    cached = cache_get(input_url)
    return cached[:media_tracks] if cached && cached[:media_tracks]

    header_str = ffmpeg_headers(headers)
    cmd = [ FFPROBE_PATH, "-v", "error" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    cmd += [
      "-show_entries",
      "stream=index,codec_type,codec_name,channels:stream_tags=language,title:stream_disposition=default,forced,hearing_impaired,comment,lyrics,karaoke",
      "-of",
      "json",
      input_url
    ]

    result = capture_command(cmd, timeout_seconds: 10)
    tracks = result.status&.success? ? extract_media_tracks(result.stdout) : empty_media_tracks
    cache_store(input_url, media_tracks: tracks)
    tracks
  rescue StandardError
    empty_media_tracks
  end

  def self.extract_subtitles_to_vtt(input_url, headers: {}, subtitle_stream: nil, start_seconds: 0, duration_seconds: SUBTITLE_EXTRACTION_WINDOW_SECONDS)
    extract_subtitles(
      input_url,
      headers: headers,
      subtitle_stream: subtitle_stream,
      start_seconds: start_seconds,
      duration_seconds: duration_seconds
    ).vtt.to_s
  end

  def self.extract_subtitles(input_url, headers: {}, subtitle_stream: nil, start_seconds: 0, duration_seconds: SUBTITLE_EXTRACTION_WINDOW_SECONDS)
    stream_index = normalized_stream_index(subtitle_stream)
    seek_start_seconds = normalized_start_seconds(start_seconds)
    extraction_duration_seconds = normalized_subtitle_duration_seconds(duration_seconds)
    unless stream_index
      result = subtitle_result(:invalid_stream, diagnostic: "invalid subtitle stream")
      log_subtitle_result(result, stream_index: subtitle_stream, start_seconds: seek_start_seconds)
      return result
    end

    track = probe_media_tracks(input_url, headers: headers)[:subtitles].find { |subtitle| subtitle[:index] == stream_index }
    unless track
      result = subtitle_result(:unsupported_track, diagnostic: "subtitle stream was not found")
      log_subtitle_result(result, stream_index: stream_index, start_seconds: seek_start_seconds)
      return result
    end

    unless track[:text_supported]
      result = subtitle_result(:unsupported_track, diagnostic: "subtitle stream is not text based")
      log_subtitle_result(result, stream_index: stream_index, start_seconds: seek_start_seconds)
      return result
    end

    packet_subtitles = extract_subtitle_packets_to_vtt(
      input_url,
      headers: headers,
      track: track,
      start_seconds: seek_start_seconds,
      duration_seconds: extraction_duration_seconds
    )
    if packet_subtitles.ok? || packet_subtitles.empty_window? || packet_subtitles.status == :timeout
      log_subtitle_result(packet_subtitles, stream_index: stream_index, start_seconds: seek_start_seconds)
      return packet_subtitles
    end

    header_str = ffmpeg_headers(headers)
    cmd = [ FFMPEG_PATH, "-loglevel", "error" ]
    cmd += [ "-analyzeduration", "1000000", "-probesize", "1000000" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    cmd += [ "-ss", seek_start_seconds.to_s ] if seek_start_seconds.positive?
    cmd += [
      "-i", input_url,
      "-t", extraction_duration_seconds.to_s,
      "-vn",
      "-an",
      "-dn",
      "-map", "0:#{stream_index}",
      "-c:s", "webvtt",
      "-f", "webvtt",
      "pipe:1"
    ]

    result = capture_subtitle_stdout_result(cmd)
    log_subtitle_result(result, stream_index: stream_index, start_seconds: seek_start_seconds)
    result
  rescue StandardError => e
    result = subtitle_result(:failed, diagnostic: e.class.name)
    log_subtitle_result(result, stream_index: subtitle_stream, start_seconds: start_seconds)
    result
  end

  def self.selectable_subtitle_tracks(tracks)
    tracks = Array(tracks)
    full_tracks = tracks.reject { |track| partial_subtitle_track?(track) }
    return sorted_subtitle_tracks(tracks) if full_tracks.empty?

    filtered_tracks = tracks.reject do |track|
      partial_subtitle_track?(track) && full_dialogue_alternative?(track, full_tracks)
    end
    sorted_subtitle_tracks(filtered_tracks)
  end

  def self.extract_subtitle_packets_to_vtt(input_url, headers:, track:, start_seconds:, duration_seconds:)
    header_str = ffmpeg_headers(headers)
    cmd = [ FFPROBE_PATH, "-v", "error" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    cmd += [
      "-select_streams", track[:index].to_s,
      "-read_intervals", "#{start_seconds}%+#{duration_seconds}",
      "-show_entries", "packet=pts_time,duration_time,data",
      "-show_data",
      "-of", "json",
      input_url
    ]

    result = capture_command(cmd, timeout_seconds: SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS)
    return subtitle_result(:timeout, source: :ffprobe_packets, diagnostic: "ffprobe packet extraction timed out") if result.timed_out
    return subtitle_result(:failed, source: :ffprobe_packets, diagnostic: "ffprobe packets exited unsuccessfully") unless result.status&.success?

    packet_result = subtitle_packets_to_webvtt(result.stdout, track[:codec], start_seconds, duration_seconds)
    if packet_result[:failed]
      subtitle_result(:failed, source: :ffprobe_packets, diagnostic: packet_result[:diagnostic])
    elsif packet_result[:cue_count].positive?
      subtitle_result(:ok, vtt: packet_result[:vtt], cue_count: packet_result[:cue_count], source: :ffprobe_packets)
    elsif packet_result[:packet_count].positive?
      subtitle_result(:failed, source: :ffprobe_packets, diagnostic: "ffprobe packets had no decodable text cues")
    else
      subtitle_result(:empty_window, source: :ffprobe_packets)
    end
  rescue StandardError => e
    subtitle_result(:failed, source: :ffprobe_packets, diagnostic: e.class.name)
  end
  private_class_method :extract_subtitle_packets_to_vtt

  def self.subtitle_packets_to_webvtt(output, codec, start_seconds, duration_seconds)
    data = JSON.parse(output)
    window_start = [ start_seconds - 5, 0 ].max
    window_end = start_seconds + duration_seconds
    cues = Array(data["packets"]).filter_map do |packet|
      subtitle_packet_to_cue(packet, codec, window_start, window_end)
    end

    {
      vtt: webvtt_from_cues(cues),
      cue_count: cues.length,
      packet_count: Array(data["packets"]).length
    }
  rescue JSON::ParserError
    { vtt: "", cue_count: 0, packet_count: 0, failed: true, diagnostic: "ffprobe packet JSON could not be parsed" }
  end
  private_class_method :subtitle_packets_to_webvtt

  def self.subtitle_packet_to_cue(packet, codec, window_start, window_end)
    start_time = finite_float(packet["pts_time"])
    return nil unless start_time

    duration = finite_float(packet["duration_time"]) || SUBTITLE_FALLBACK_DURATION_SECONDS
    duration = SUBTITLE_FALLBACK_DURATION_SECONDS unless duration.positive?
    end_time = start_time + duration
    return nil if end_time < window_start || start_time > window_end

    text = subtitle_packet_text(packet["data"], codec)
    return nil if text.blank?

    { start: start_time, end: end_time, text: text }
  end
  private_class_method :subtitle_packet_to_cue

  def self.subtitle_packet_text(data, codec)
    text = decode_ffprobe_packet_data(data)
    return "" if text.blank?

    text = ass_packet_text(text) if %w[ass ssa].include?(codec.to_s)
    normalize_subtitle_text(text)
  end
  private_class_method :subtitle_packet_text

  def self.decode_ffprobe_packet_data(data)
    bytes = data.to_s.each_line.flat_map do |line|
      hex = line[/:\s*((?:[[:xdigit:]]{2,4}\s*)+)/, 1]
      hex ? hex.scan(/[[:xdigit:]]{2}/).map { |byte| byte.to_i(16) } : []
    end
    bytes.pack("C*").force_encoding(Encoding::UTF_8).scrub
  end
  private_class_method :decode_ffprobe_packet_data

  def self.ass_packet_text(text)
    text.split(",", 9).last.to_s
  end
  private_class_method :ass_packet_text

  def self.normalize_subtitle_text(text)
    text
      .gsub(/\{[^}]*\}/, "")
      .gsub(/\\[Nn]/, "\n")
      .gsub(/<[^>]+>/, "")
      .lines
      .map(&:strip)
      .reject(&:blank?)
      .join("\n")
  end
  private_class_method :normalize_subtitle_text

  def self.webvtt_from_cues(cues)
    return "" if cues.empty?

    body = cues
      .sort_by { |cue| cue[:start] }
      .map do |cue|
        "#{format_vtt_timestamp(cue[:start])} --> #{format_vtt_timestamp(cue[:end])}\n#{cue[:text]}"
      end
      .join("\n\n")
    "WEBVTT\n\n#{body}\n"
  end
  private_class_method :webvtt_from_cues

  def self.format_vtt_timestamp(seconds)
    milliseconds = (seconds.to_f * 1000).round
    hours = milliseconds / 3_600_000
    milliseconds %= 3_600_000
    minutes = milliseconds / 60_000
    milliseconds %= 60_000
    whole_seconds = milliseconds / 1000
    milliseconds %= 1000

    format("%02d:%02d:%02d.%03d", hours, minutes, whole_seconds, milliseconds)
  end
  private_class_method :format_vtt_timestamp

  def self.build_ffmpeg_command(input_url, headers: {}, start_seconds: 0, audio_stream: nil, subtitle_stream: nil, default_language: nil, preferred_languages: [], output_spec: :fmp4, segment_dir: nil, remux: false, telemetry_id: nil)
    header_str = ffmpeg_headers(headers)
    # Probe video stream and media tracks in parallel — these are
    # independent ffprobe calls that each take 1-3s on a cold cache.
    # Running them concurrently halves the probe latency.
    video_stream = nil
    probe_thread = Thread.new { video_stream = probe_video_stream(input_url, headers: headers) }
    # probe_media_tracks is called inside selected_audio_stream_index
    # and selected_burn_subtitle_track; running it now warms the cache
    # so both callers get the cached result.
    media_tracks_thread = Thread.new { probe_media_tracks(input_url, headers: headers) }
    probe_thread.join
    media_tracks_thread.join

    selected_audio_index = selected_audio_stream_index(
      input_url,
      headers: headers,
      audio_stream: audio_stream,
      default_language: default_language,
      preferred_languages: preferred_languages
    )
    selected_burn_subtitle_track = selected_burn_subtitle_track(input_url, headers: headers, subtitle_stream: subtitle_stream)
    seek_start_seconds = normalized_start_seconds(start_seconds)
    # Remux mode: copy video stream verbatim (-c:v copy) with no decode,
    # scale, or re-encode.  Runs at near network speed.  Only used when
    # the frontend detects H.264 or HEVC video and requests remux=1.
    # Subtitle burn requires re-encoding video, so remux is ignored if a
    # burn subtitle track is selected — falls through to normal transcode.
    #
    # Remux mode copies video for both initial playback and keyframe-aligned
    # seeks.  The browser asks the seek-plan endpoint for the preceding
    # keyframe, sends that anchor as start_seconds, then skips the short
    # pre-roll locally.  Standard MSE seeks still transcode for exactness.
    effective_remux = remux && !selected_burn_subtitle_track
    video_args = if selected_burn_subtitle_track
      transcode_args
    elsif effective_remux
      [ "-c:v", "copy" ]
    elsif browser_safe_video?(video_stream) && seek_start_seconds.zero?
      [ "-c:v", "copy" ]
    else
      [ "-vf", SAFE_VIDEO_FILTER, *transcode_args ]
    end

    if defined?(Rails)
      encoder = video_args.each_cons(2).find { |key, _| key == "-c:v" }&.last || "copy"
      id = sanitize_telemetry_id(telemetry_id)
      Rails.logger.info(
        "[Transcode] playback_id=#{id} codec=#{video_stream[:codec_name]} " \
        "resolution=#{video_stream[:width]}x#{video_stream[:height]} encoder=#{encoder} " \
        "start_seconds=#{seek_start_seconds.round(2)} remux=#{effective_remux}"
      )
    end

    cmd = [ FFMPEG_PATH, "-loglevel", "error" ]
    # fMP4/remux reads as fast as the bounded producer/consumer queues
    # allow. HLS applies its own realtime pacing plus initial burst below.
    # Reconnect on HTTP connection drops — RealDebrid CDN / Cloudflare
    # may close the connection after a period.  Without reconnect,
    # ffmpeg exits when the upstream dies.  With reconnect, ffmpeg
    # retries up to -reconnect_delay_max seconds.
    cmd += [ "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5" ]
    # Read timeout on the input socket: if no bytes arrive for this long,
    # ffmpeg exits with an error instead of blocking forever on a stalled
    # RealDebrid CDN connection.  -reconnect only fires on connection-level
    # close, not on a stalled-but-open socket.  30s matches the frontend's
    # FIRST_DATA_TIMEOUT_SECONDS and is long enough to absorb normal CDN
    # latency spikes.  Applies to the HTTP/HTTPS input protocol only.
    # Microseconds: 30_000_000 = 30s.
    cmd += [ "-rw_timeout", "30000000" ]
    # Hardware acceleration for decode.  On macOS with VideoToolbox,
    # -hwaccel videotoolbox offloads HEVC/H.264 decode to the GPU,
    # which is critical for 4K HEVC streams — software HEVC decode
    # is the single biggest bottleneck even on fast CPUs.  The decoded
    # frames are in system memory (default output format), so the
    # software scale/format filter below can process them normally.
    cmd += hwaccel_args if video_args != [ "-c:v", "copy" ]
    # Generate only missing presentation timestamps from decode timestamps.
    # This is an input flag, so it must precede -i; applying it to only the
    # fMP4 output left HLS and inputs with incomplete PTS untreated.
    cmd += [ "-fflags", "+genpts" ]
    # Moderate probe limits -- enough for MKV and MPEG-TS (M2TS).
    # M2TS needs more data than MKV because PAT/PMT tables are
    # interleaved every ~100ms in 188-byte packets. 32K was too
    # small and caused ffmpeg to hang on M2TS files. 5M (default)
    # is too much for large remote files. 1M is the sweet spot.
    cmd += [ "-analyzeduration", "1000000", "-probesize", "1000000" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    if output_spec == :hls
      # Build an initial playback cushion, then pace production at realtime.
      # This prevents a max-speed producer from racing so far ahead that
      # consumer-aware segment cleanup removes media before Safari requests it.
      cmd += [ "-readrate", HLS_READ_RATE, "-readrate_initial_burst", HLS_INITIAL_BURST_SECONDS.to_s ]
    end
    cmd << "-noaccurate_seek" if effective_remux && seek_start_seconds.positive?
    # Input seeking (before -i): fast, uses the container's seek table.
    cmd += [ "-ss", seek_start_seconds.to_s ] if seek_start_seconds.positive?
    cmd += [ "-i", input_url ]
    if selected_burn_subtitle_track
      cmd += [ "-filter_complex", subtitle_burn_filter(selected_burn_subtitle_track[:position]) ]
      cmd += [ "-map", "[v]" ]
    else
      cmd += [ "-map", "0:v:0" ]
    end
    cmd += if selected_audio_index
      [ "-map", "0:#{selected_audio_index}" ]
    else
      [ "-map", "0:a:0?" ]
    end
    cmd += [ "-sn", "-dn" ]
    cmd += video_args
    if video_args != [ "-c:v", "copy" ]
      cmd += [ "-force_key_frames", "expr:gte(t,n_forced*#{KEYFRAME_INTERVAL_SECONDS})" ]
    end
    # with the source timestamps.  Copying AAC bypassed synchronization for
    # timestamp gaps/discontinuities, while async=1 on other codecs only did
    # hard fill/trim and could not correct gradual clock drift.  first_pts=0
    # also puts delayed/early audio on the same zero-based timeline as video.
    cmd += [ "-c:a", "aac", "-b:a", "192k", "-ac", "2",
             "-af", AUDIO_SYNC_FILTER ]
    cmd += case output_spec
    when :hls
      raise ArgumentError, "segment_dir is required for HLS output" if segment_dir.blank?
      [
        "-f", "hls",
        "-hls_time", HLS_SEGMENT_DURATION.to_s,
        "-hls_playlist_type", "event",
        "-hls_segment_type", "mpegts",
        "-hls_flags", HLS_FLAGS,
        "-hls_segment_filename", File.join(segment_dir, "%d.ts"),
        File.join(segment_dir, "playlist.m3u8")
      ]
    else  # :fmp4 (default)
      [
        "-f", "mp4",
        "-movflags", FMP4_FLAGS,
        # No -frag_duration: with +frag_keyframe, ffmpeg fragments at
        # keyframes only, ensuring every fragment starts with a random
        # access point as Chrome's MSE chunk demuxer requires.  Setting
        # frag_duration forces fragments at fixed time intervals that
        # don't align with keyframes → CHUNK_DEMUXER_ERROR_APPEND_FAILED.
        "pipe:1"
      ]
    end
    cmd
  end
  private_class_method :build_ffmpeg_command

  # Return the best available H.264 encoder args.  Order of precedence:
  #   1. FFMPEG_ENCODER env var (for Docker/cloud with a hardware encoder)
  #   2. VideoToolbox auto-detection (macOS)
  #   3. libx264 ultrafast with -threads auto (software, works everywhere)
  #
  # For a production Linux server with Intel QuickSync (VAAPI):
  #   FFMPEG_ENCODER="h264_vaapi -b:v 5000k -global_quality 23"
  #
  # For NVIDIA GPU (NVENC):
  #   FFMPEG_ENCODER="h264_nvenc -preset p7 -b:v 5000k -rc vbr"
  def self.transcode_args
    env = ENV["FFMPEG_ENCODER"].to_s.strip
    return Shellwords.split(env) if env.present?

    return VIDEOTOOLBOX_TRANSCODE_ARGS if videotoolbox_available?

    VIDEO_TRANSCODE_ARGS
  end
  private_class_method :transcode_args

  def self.videotoolbox_available?
    return @videotoolbox_available if defined?(@videotoolbox_available)

    result = capture_command([ FFMPEG_PATH, "-hide_banner", "-encoders" ], timeout_seconds: 5)
    @videotoolbox_available = result.status&.success? && result.stdout.include?("h264_videotoolbox")
  end
  private_class_method :videotoolbox_available?

  # Return hardware acceleration flags for decode.  Order of precedence:
  #   1. FFMPEG_HWACCEL env var (for Docker/cloud deployments with a GPU)
  #   2. VideoToolbox auto-detection (macOS)
  #   3. Empty (software decode — works everywhere)
  #
  # For a production Linux server with an Intel GPU (QuickSync):
  #   FFMPEG_HWACCEL="-hwaccel vaapi -vaapi_device /dev/dri/renderD128 -hwaccel_output_format vaapi"
  #
  # For NVIDIA GPU (CUDA/NVENC):
  #   FFMPEG_HWACCEL="-hwaccel cuda -hwaccel_output_format cuda"
  def self.hwaccel_args
    env = ENV["FFMPEG_HWACCEL"].to_s.strip
    return Shellwords.split(env) if env.present?

    return [ "-hwaccel", "videotoolbox" ] if videotoolbox_available?

    []
  end
  private_class_method :hwaccel_args

  def self.selected_burn_subtitle_track(input_url, headers:, subtitle_stream:)
    explicit_stream_index = normalized_stream_index(subtitle_stream)
    return nil unless explicit_stream_index

    track = probe_media_tracks(input_url, headers: headers)[:subtitles].find do |track|
      track[:index] == explicit_stream_index
    end
    return nil if track&.dig(:text_supported)

    track
  end
  private_class_method :selected_burn_subtitle_track

  def self.subtitle_burn_filter(subtitle_position)
    "[0:v:0][0:s:#{subtitle_position}]overlay,#{SAFE_VIDEO_FILTER}[v]"
  end
  private_class_method :subtitle_burn_filter

  def self.capture_subtitle_stdout(cmd)
    capture_subtitle_stdout_result(cmd).vtt.to_s
  end
  private_class_method :capture_subtitle_stdout

  def self.capture_subtitle_stdout_result(cmd)
    rd, wr = IO.pipe
    err_rd, err_wr = IO.pipe
    pid = Process.spawn(*cmd, in: "/dev/null", out: wr, err: err_wr, pgroup: true)
    wr.close
    err_wr.close

    stdout_buf = +""
    reaped = false

    stdout_thread = Thread.new do
      loop do
        chunk = rd.readpartial(4096)
        stdout_buf << chunk
      end
    rescue EOFError, IOError, Errno::EBADF
    end

    stderr_thread = Thread.new do
      loop { err_rd.readpartial(4096) }
    rescue EOFError, IOError, Errno::EBADF
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SUBTITLE_EXTRACTION_TIMEOUT_SECONDS
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      if status
        reaped = true
        stdout_thread.join(1)
        stderr_thread.join(1)
        return subtitle_result(:ok, vtt: stdout_buf, cue_count: webvtt_cue_count(stdout_buf), source: :ffmpeg) if status.success? && webvtt_has_cues?(stdout_buf)
        return subtitle_result(:empty_window, source: :ffmpeg) if status.success?

        return subtitle_result(:failed, source: :ffmpeg, diagnostic: "ffmpeg subtitle extraction exited unsuccessfully")
      end

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        return subtitle_result(:ok, vtt: stdout_buf, cue_count: webvtt_cue_count(stdout_buf), source: :ffmpeg) if webvtt_has_cues?(stdout_buf)

        return subtitle_result(:timeout, source: :ffmpeg, diagnostic: "ffmpeg subtitle extraction timed out")
      end

      sleep 0.1
    end
  ensure
    kill_process_group(pid) if pid && !reaped
    stdout_thread&.kill
    stderr_thread&.kill
    stdout_thread&.join(1)
    stderr_thread&.join(1)
    rd&.close unless rd&.closed?
    err_rd&.close unless err_rd&.closed?
  end
  private_class_method :capture_subtitle_stdout_result

  def self.webvtt_has_cues?(text)
    text.to_s.match?(/^\d{2}:\d{2}(?::\d{2})?[\.,]\d{3}\s+-->/)
  end
  private_class_method :webvtt_has_cues?

  def self.webvtt_cue_count(text)
    text.to_s.scan(/^\d{2}:\d{2}(?::\d{2})?[\.,]\d{3}\s+-->/).length
  end
  private_class_method :webvtt_cue_count

  def self.subtitle_result(status, vtt: "", cue_count: 0, source: nil, diagnostic: nil)
    SubtitleExtractionResult.new(
      status: status,
      vtt: vtt.to_s,
      cue_count: cue_count.to_i,
      source: source,
      diagnostic: diagnostic
    )
  end
  private_class_method :subtitle_result

  def self.log_subtitle_result(result, stream_index:, start_seconds:)
    return unless defined?(Rails)

    Rails.logger.info(
      "[Subtitles] status=#{result.status} source=#{result.source || 'none'} " \
      "stream=#{stream_index.presence || 'none'} start=#{normalized_start_seconds(start_seconds)} " \
      "cues=#{result.cue_count}"
    )
  end
  private_class_method :log_subtitle_result

  # Returns the selected audio stream index or nil. Selection order:
  #   1. Explicit stream index (audio_stream param) if it exists.
  #   2. Preferred language track (lowest position wins on ties).
  #   3. Track marked default.
  #   4. First audio track.
  def self.selected_audio_stream_index(input_url, headers:, audio_stream:, default_language:, preferred_languages:)
    explicit_stream_index = normalized_stream_index(audio_stream)
    tracks = probe_media_tracks(input_url, headers: headers)[:audio]

    return explicit_stream_index if explicit_stream_index && tracks.any? { |track| track[:index] == explicit_stream_index }

    language_priority = language_priority(default_language, preferred_languages)
    preferred_track = tracks
      .select { |track| language_priority.include?(track[:language]) }
      .min_by { |track| [ language_priority.index(track[:language]), track[:position] ] }
    return preferred_track[:index] if preferred_track

    default_track = tracks.find { |track| track[:default] }
    return default_track[:index] if default_track

    tracks.first&.dig(:index)
  end
  private_class_method :selected_audio_stream_index

  def self.extract_media_tracks(output)
    data = JSON.parse(output)
    audio_position = 0
    subtitle_position = 0
    tracks = empty_media_tracks

    Array(data["streams"]).each do |stream|
      stream_index = non_negative_integer(stream["index"])
      next unless stream_index

      case stream["codec_type"].to_s
      when "audio"
        tracks[:audio] << media_track(stream, stream_index, audio_position)
        audio_position += 1
      when "subtitle"
        subtitle_track = media_track(stream, stream_index, subtitle_position)
        subtitle_track[:text_supported] = TEXT_SUBTITLE_CODECS.include?(subtitle_track[:codec])
        annotate_subtitle_track!(subtitle_track, stream)
        tracks[:subtitles] << subtitle_track
        subtitle_position += 1
      end
    end

    tracks
  rescue JSON::ParserError
    empty_media_tracks
  end
  private_class_method :extract_media_tracks

  def self.media_track(stream, stream_index, position)
    tags = stream["tags"] || {}
    language = canonical_language(tags["language"])
    codec = stream["codec_name"].to_s.downcase
    channels = positive_integer(stream["channels"])
    title = tags["title"].to_s.presence
    default = stream.dig("disposition", "default").to_i == 1

    {
      index: stream_index,
      position: position,
      language: language,
      language_label: language_label(language),
      title: title,
      codec: codec,
      channels: channels,
      default: default,
      label: track_label(language, title, codec, channels, default)
    }
  end
  private_class_method :media_track

  def self.annotate_subtitle_track!(track, stream)
    disposition = stream["disposition"] || {}
    title = track[:title].to_s
    forced = truthy_disposition?(disposition, "forced") || title.match?(/\bforced\b/i)
    hearing_impaired = truthy_disposition?(disposition, "hearing_impaired") || title.match?(HEARING_IMPAIRED_TITLE_PATTERN)
    commentary = truthy_disposition?(disposition, "comment") || title.match?(/\bcomment(?:ary)?\b/i)
    lyrics = truthy_disposition?(disposition, "lyrics") || truthy_disposition?(disposition, "karaoke") || title.match?(/\b(?:lyrics?|karaoke)\b/i)
    partial = forced || commentary || lyrics || title.match?(PARTIAL_SUBTITLE_TITLE_PATTERN)

    track[:forced] = forced
    track[:hearing_impaired] = hearing_impaired
    track[:commentary] = commentary
    track[:partial] = partial
    track[:quality] = partial ? "partial" : "full"
    track[:quality_score] = subtitle_quality_score(track)
    track[:label] = subtitle_track_label(track)
  end
  private_class_method :annotate_subtitle_track!

  def self.truthy_disposition?(disposition, key)
    disposition[key].to_i == 1
  end
  private_class_method :truthy_disposition?

  def self.partial_subtitle_track?(track)
    track[:partial] == true || track["partial"] == true
  end
  private_class_method :partial_subtitle_track?

  def self.full_dialogue_alternative?(track, full_tracks)
    language = track[:language] || track["language"]
    return full_tracks.any? if language.blank?

    full_tracks.any? { |candidate| (candidate[:language] || candidate["language"]) == language }
  end
  private_class_method :full_dialogue_alternative?

  def self.sorted_subtitle_tracks(tracks)
    tracks.sort_by do |track|
      [
        track[:quality_score] || track["quality_score"] || 0,
        track[:external] || track["external"] ? 0 : 1,
        track[:position] || track["position"] || MAX_STREAM_INDEX,
        track[:label] || track["label"].to_s
      ]
    end
  end
  private_class_method :sorted_subtitle_tracks

  def self.subtitle_quality_score(track)
    score = 0
    score += 100 if track[:partial]
    score += 20 if track[:hearing_impaired]
    score += 10 unless track[:text_supported]
    score -= 5 if track[:default]
    score
  end
  private_class_method :subtitle_quality_score

  def self.subtitle_track_label(track)
    parts = [ language_label(track[:language]) ]
    parts << track[:title] if track[:title].present?
    parts << "Forced" if track[:forced] && !track[:title].to_s.match?(/\bforced\b/i)
    parts << "SDH" if track[:hearing_impaired] && !track[:title].to_s.match?(HEARING_IMPAIRED_TITLE_PATTERN)
    parts << "Partial" if track[:partial] && !track[:forced] && !track[:commentary]
    parts << track[:codec].upcase if track[:codec].present?
    parts << "Default" if track[:default]
    parts.compact_blank.uniq.join(" · ")
  end
  private_class_method :subtitle_track_label

  def self.track_label(language, title, codec, channels, default)
    parts = [ language_label(language) ]
    parts << title if title.present?
    parts << "#{channels}ch" if channels
    parts << codec.upcase if codec.present?
    parts << "Default" if default
    parts.join(" · ")
  end
  private_class_method :track_label

  def self.language_priority(default_language, preferred_languages)
    ([ default_language ] + Array(preferred_languages))
      .filter_map { |language| canonical_language(language) }
      .uniq
  end
  private_class_method :language_priority

  def self.canonical_language(value)
    normalized = value.to_s.downcase.strip
    return nil if normalized.blank? || normalized == "und"

    LANGUAGE_ALIASES.find { |_, aliases| aliases.include?(normalized) }&.first
  end
  private_class_method :canonical_language

  def self.language_label(language)
    return "Unknown" if language.blank?

    User::STREAM_LANGUAGE_OPTIONS[language] || language
  end
  private_class_method :language_label

  def self.normalized_stream_index(value)
    stream_index = Integer(value, exception: false)
    return nil unless stream_index && stream_index.between?(0, MAX_STREAM_INDEX)

    stream_index
  end
  private_class_method :normalized_stream_index

  def self.empty_media_tracks
    { audio: [], subtitles: [] }
  end
  private_class_method :empty_media_tracks

  def self.probe_video_stream(input_url, headers: {})
    cached = cache_get(input_url)
    return cached[:video_stream] if cached&.key?(:video_stream)

    header_str = ffmpeg_headers(headers)
    cmd = [ FFPROBE_PATH, "-v", "error" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    cmd += [
      "-select_streams", "v:0",
      "-show_entries", "stream=codec_name,width,height,pix_fmt,has_b_frames",
      "-of", "json",
      input_url
    ]

    result = capture_command(cmd, timeout_seconds: 10)
    stream = result.status&.success? ? extract_video_stream(result.stdout) : {}
    cache_store(input_url, video_stream: stream)
    stream
  rescue StandardError
    {}
  end
  public_class_method :probe_video_stream

  # Find the keyframe immediately preceding a remux seek target.  Stream
  # copy cannot start on an arbitrary inter-frame packet, so the browser
  # starts this short pre-roll and advances locally to the exact target.
  # Returns nil when the source cannot provide a trustworthy seek anchor;
  # callers must fall back to accurate transcoding in that case.
  def self.probe_remux_seek(input_url, target_seconds:, headers: {})
    target = normalized_start_seconds(target_seconds)
    return { anchor_seconds: 0.0, skip_seconds: 0.0 } if target.zero?

    header_str = ffmpeg_headers(headers)
    cmd = [ FFPROBE_PATH, "-v", "error" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    cmd += [
      "-select_streams", "v:0",
      "-skip_frame", "nokey",
      "-read_intervals", "#{target}%+0.1",
      "-show_entries", "frame=best_effort_timestamp_time",
      "-of", "json",
      input_url
    ]

    result = capture_command(cmd, timeout_seconds: REMUX_KEYFRAME_PROBE_TIMEOUT_SECONDS)
    return nil unless result.status&.success? && !result.timed_out

    data = JSON.parse(result.stdout)
    anchor = Array(data["frames"])
      .filter_map { |frame| finite_float(frame["best_effort_timestamp_time"]) }
      .select { |timestamp| timestamp >= 0 && timestamp <= target + 0.25 }
      .max
    return nil unless anchor

    skip = target - anchor
    return nil if skip.negative? || skip > MAX_REMUX_PREROLL_SECONDS

    { anchor_seconds: anchor, skip_seconds: skip }
  rescue JSON::ParserError, StandardError
    nil
  end
  public_class_method :probe_remux_seek

  def self.extract_video_stream(output)
    data = JSON.parse(output)
    stream = Array(data["streams"]).first || {}
    {
      codec_name: stream["codec_name"].to_s.downcase,
      width: positive_integer(stream["width"]),
      height: positive_integer(stream["height"]),
      pix_fmt: stream["pix_fmt"].to_s.downcase,
      has_b_frames: positive_integer(stream["has_b_frames"]).to_i > 0
    }
  rescue JSON::ParserError
    {}
  end
  private_class_method :extract_video_stream

  def self.browser_safe_video?(stream)
    return false unless stream.is_a?(Hash)

    codec = stream[:codec_name].to_s
    width = stream[:width].to_i
    height = stream[:height].to_i
    pix_fmt = stream[:pix_fmt].to_s

    codec == "h264" &&
      width.positive? &&
      height.positive? &&
      width <= MAX_COPY_VIDEO_WIDTH &&
      height <= MAX_COPY_VIDEO_HEIGHT &&
      SAFE_H264_PIXEL_FORMATS.include?(pix_fmt) &&
      !stream[:has_b_frames]
    # Sources with B-frames cannot be stream-copied to fragmented MP4 for
    # MSE: +frag_keyframe fragments at keyframes in display order, but the
    # first packet by DTS in each fragment is a B-frame that depends on
    # the previous fragment's keyframe.  Chrome's MSE chunk demuxer rejects
    # these fragments with CHUNK_DEMUXER_ERROR_APPEND_FAILED.  Forcing a
    # re-encode (without B-frames) avoids the decode error.
  end
  public_class_method :browser_safe_video?

  def self.positive_integer(value)
    integer = Integer(value, exception: false)
    integer&.positive? ? integer : nil
  end
  private_class_method :positive_integer

  def self.finite_float(value)
    number = Float(value, exception: false)
    number if number&.finite?
  end
  private_class_method :finite_float

  def self.non_negative_integer(value)
    integer = Integer(value, exception: false)
    integer && integer >= 0 ? integer : nil
  end
  private_class_method :non_negative_integer

  def self.normalized_start_seconds(value)
    seconds = value.to_f
    seconds.finite? && seconds.positive? ? seconds : 0
  end
  private_class_method :normalized_start_seconds

  def self.normalized_subtitle_duration_seconds(value)
    seconds = value.to_i
    return SUBTITLE_EXTRACTION_WINDOW_SECONDS unless seconds.positive?

    seconds.clamp(MIN_SUBTITLE_EXTRACTION_WINDOW_SECONDS, MAX_SUBTITLE_EXTRACTION_WINDOW_SECONDS)
  end
  private_class_method :normalized_subtitle_duration_seconds

  def self.extract_probe_duration(output)
    data = JSON.parse(output)
    durations = []
    durations << data.dig("format", "duration")
    durations << data.dig("format", "tags", "DURATION")

    Array(data["streams"]).each do |stream|
      durations << stream["duration"]
      tags = stream["tags"] || {}
      durations << tags["DURATION"]
      durations << tags["duration"]
    end

    durations
      .filter_map { |value| parse_probe_duration_value(value) }
      .select { |duration| valid_probe_duration?(duration) }
      .max || 0
  rescue JSON::ParserError
    duration = parse_probe_duration_value(output)
    valid_probe_duration?(duration) ? duration : 0
  end
  private_class_method :extract_probe_duration

  def self.parse_probe_duration_value(value)
    text = value.to_s.strip
    return nil if text.blank? || text.casecmp("N/A").zero?

    if text.match?(/\A\d+(?:\.\d+)?\z/)
      return text.to_f
    end

    parts = text.split(":")
    return nil unless parts.length.between?(2, 3) && parts.all? { |part| part.match?(/\A\d+(?:\.\d+)?\z/) }

    seconds = parts.pop.to_f
    minutes = parts.pop.to_i
    hours = parts.pop.to_i
    (hours * 3600) + (minutes * 60) + seconds
  end
  private_class_method :parse_probe_duration_value

  def self.valid_probe_duration?(duration)
    duration.is_a?(Numeric) &&
      duration.finite? &&
      duration >= MIN_VALID_DURATION_SECONDS &&
      duration <= MAX_VALID_DURATION_SECONDS
  end
  private_class_method :valid_probe_duration?

  # ── Probe cache ───────────────────────────────────────────────────
  # Thread-safe in-memory cache shared within a Puma worker.
  # Multiple workers each maintain their own cache (acceptable tradeoff
  # vs. the latency of a Redis round-trip on every probe).

  @probe_cache_mutex = Mutex.new

  def self.cache_get(url)
    @probe_cache_mutex.synchronize do
      entry = @probe_cache[url]
      return nil unless entry
      # Use monotonic clock for expiry — wall-clock (Time.now) can jump
      # backward on NTP steps, making entries immortal until the clock
      # catches up.  The rest of the file uses CLOCK_MONOTONIC for
      # deadlines; the cache was the odd one out.
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > entry[:expires_at]
        @probe_cache.delete(url)
        return nil
      end
      entry
    end
  end
  private_class_method :cache_get

  def self.cache_store(url, **fields)
    @probe_cache_mutex.synchronize do
      while @probe_cache.size >= PROBE_CACHE_MAX_SIZE
        oldest_key = @probe_cache.min_by { |_, entry| entry[:expires_at] }&.first
        break unless oldest_key
        @probe_cache.delete(oldest_key)
      end
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      existing = @probe_cache[url] || { expires_at: now + PROBE_CACHE_TTL }
      @probe_cache[url] = existing.merge(fields).merge(expires_at: now + PROBE_CACHE_TTL)
    end
  end
  private_class_method :cache_store

  def self.ffmpeg_headers(headers)
    headers.filter_map do |key, value|
      key = key.to_s
      value = value.to_s
      next if key.blank? || value.blank?
      next if key.match?(/[\r\n:]/) || value.match?(/[\r\n]/)

      "#{key}: #{value}"
    end.join("\r\n")
  end
  private_class_method :ffmpeg_headers

  # ── Helpers ───────────────────────────────────────────────────────

  def self.stderr_summary(buf)
    s = buf.strip
    return "" if s.empty?
    # Keep only the tail (most relevant — the actual error line)
    s = s[-STDERR_MAX_BYTES..] if s.bytesize > STDERR_MAX_BYTES
    "stderr: #{s}"
  end
  private_class_method :stderr_summary

  def self.sanitize_telemetry_id(value)
    sanitized = value.to_s.gsub(/[^a-zA-Z0-9_-]/, "").first(80)
    sanitized.empty? ? "unknown" : sanitized
  end
  private_class_method :sanitize_telemetry_id

  # ── Process management ────────────────────────────────────────────

  def self.capture_command(cmd, timeout_seconds:)
    stdout_rd = nil
    stdout_wr = nil
    stderr_rd = nil
    stderr_wr = nil
    stdout_thread = nil
    stderr_thread = nil
    pid = nil
    status = nil
    timed_out = false
    reaped = false
    stdout_buf = +""
    stderr_buf = +""

    stdout_rd, stdout_wr = IO.pipe
    stderr_rd, stderr_wr = IO.pipe
    pid = Process.spawn(*cmd, in: File::NULL, out: stdout_wr, err: stderr_wr, pgroup: true)
    stdout_wr.close
    stderr_wr.close

    stdout_thread = drain_pipe(stdout_rd, stdout_buf)
    stderr_thread = drain_pipe(stderr_rd, stderr_buf)

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      if status
        reaped = true
        break
      end

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        timed_out = true
        kill_process_group(pid)
        reaped = true
        break
      end

      sleep 0.05
    end

    stdout_thread.join(1)
    stderr_thread.join(1)

    CommandCaptureResult.new(
      stdout: stdout_buf,
      stderr: stderr_buf,
      status: status,
      timed_out: timed_out
    )
  ensure
    kill_process_group(pid) if pid && !reaped
    stdout_thread&.kill
    stderr_thread&.kill
    stdout_thread&.join(1)
    stderr_thread&.join(1)
    [ stdout_rd, stdout_wr, stderr_rd, stderr_wr ].each do |io|
      io&.close unless io&.closed?
    end
  end
  private_class_method :capture_command

  def self.drain_pipe(io, buffer)
    Thread.new do
      loop { buffer << io.readpartial(4096) }
    rescue EOFError, IOError, Errno::EBADF
    end
  end
  private_class_method :drain_pipe

  # Kill the ffmpeg process group: SIGTERM first, then SIGKILL if it
  # doesn't exit within the grace period.  Safe to call if already dead.
  #
  # macOS returns EPERM (not ESRCH) when signaling a process group whose
  # leader has already exited, so we treat EPERM as "try reaping, maybe
  # still alive" rather than a hard failure.
  def self.kill_process_group(pid)
    return if pid.nil?

    # Resume the process if it's stopped (SIGTTIN/SIGTSTP can stop a
    # background process group member). A stopped process can't receive
    # SIGTERM/SIGKILL until SIGCONT is sent first.
    signal_group(pid, "CONT")

    signaled = signal_group(pid, "TERM")
    unless signaled
      waitpid_safely(pid)
      return
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SHUTDOWN_GRACE_SECONDS
    while group_alive?(pid)
      reaped?(pid)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end

    signal_group(pid, "KILL") if group_alive?(pid)
    waitpid_safely(pid)
  end
  private_class_method :kill_process_group

  # Send a signal to the process group. Returns true if the signal was
  # delivered (process may still be alive), false if it's already gone.
  def self.signal_group(pid, sig)
    Process.kill(sig, -pid)  # negative PID → entire process group
    true
  rescue Errno::ESRCH
    false  # already exited
  rescue Errno::EPERM
    # macOS: group leader gone.  Check if the PID itself is still alive.
    alive?(pid)
  end
  private_class_method :signal_group

  def self.alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end
  private_class_method :alive?

  def self.group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
  private_class_method :group_alive?

  # Has the process exited and been reaped?  Returns true only when the
  # PID no longer exists (waitpid reaped it, or it was never our child).
  def self.reaped?(pid)
    _, status = Process.waitpid2(pid, Process::WNOHANG)
    !status.nil?  # nil → still running; truthy → exited
  rescue Errno::ESRCH, Errno::ECHILD
    true
  end
  private_class_method :reaped?

  def self.waitpid_safely(pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already reaped
  end
  private_class_method :waitpid_safely
end
