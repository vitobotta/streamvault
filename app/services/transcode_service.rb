# frozen_string_literal: true

require "json"

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
  FMP4_FLAGS = "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets"
  SHUTDOWN_GRACE_SECONDS = 1
  FIRST_DATA_TIMEOUT_SECONDS = 30
  # No mid-stream idle timeout: ffmpeg produces data in bursts, and
  # pausing between bursts is normal. The frontend watchdog detects
  # true playback stalls (video element buffer ran dry) — the backend
  # cannot distinguish a transcoding pause from a real stall.
  MIN_VALID_DURATION_SECONDS = 60
  MAX_VALID_DURATION_SECONDS = 24 * 60 * 60
  MAX_STREAM_INDEX = 200
  SUBTITLE_EXTRACTION_TIMEOUT_SECONDS = 45
  SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS = 12
  FORCED_SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS = 8
  SUBTITLE_EXTRACTION_WINDOW_SECONDS = 15
  MIN_SUBTITLE_EXTRACTION_WINDOW_SECONDS = 5
  MAX_SUBTITLE_EXTRACTION_WINDOW_SECONDS = 60
  SUBTITLE_FALLBACK_DURATION_SECONDS = 4
  MAX_COPY_VIDEO_WIDTH = 1920
  MAX_COPY_VIDEO_HEIGHT = 1080
  SAFE_VIDEO_FILTER =
    "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p"
  VIDEO_TRANSCODE_ARGS = [
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-crf", "23",
    "-profile:v", "high",
    "-pix_fmt", "yuv420p"
  ].freeze
  VIDEOTOOLBOX_TRANSCODE_ARGS = [
    "-c:v", "h264_videotoolbox",
    "-b:v", "4000k",
    "-pix_fmt", "yuv420p"
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
  PROBE_CACHE_TTL = 300 # 5 minutes
  PROBE_CACHE_MAX_SIZE = 100

  class TranscodeError < StandardError; end

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
  def self.transcode_to_fmp4(input_url, headers: {}, start_seconds: 0, audio_stream: nil, subtitle_stream: nil, default_language: nil, preferred_languages: [], &block)
    cmd = build_ffmpeg_command(
      input_url,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages
    )

    transcode_to_fmp4_internal(cmd, &block)
  end

  # Spawns a subprocess from the given command array, streams its stdout
  # in 32 KB chunks to the block, and enforces first-data and idle
  # timeouts.  Raises TranscodeError if the process stalls or exits
  # without producing data.  Extracted from transcode_to_fmp4 so the
  # timeout logic can be tested without a real ffmpeg binary.
  def self.transcode_to_fmp4_internal(cmd, &block)
    rd, wr = IO.pipe
    err_rd, err_wr = IO.pipe
    pid = Process.spawn(*cmd, in: "/dev/null", out: wr, err: err_wr, pgroup: true)
    wr.close
    err_wr.close

    # Drain stderr in background to prevent pipe-buffer deadlock and
    # capture diagnostics for TranscodeError when ffmpeg fails.
    stderr_buf = +""
    stderr_thread = Thread.new do
      loop { stderr_buf << err_rd.readpartial(4096) }
    rescue EOFError, IOError, Errno::EBADF
    end

    begin
      produced_output = false
      total_bytes = 0
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # readpartial returns whatever data is available (up to 32 KB)
      # without waiting for the full amount, then blocks for more.
      # When ffmpeg closes stdout (exit), it raises EOFError.
      #
      # Only the FIRST_DATA_TIMEOUT_SECONDS guard is applied — before
      # ffmpeg produces any data.  Once data starts flowing, we read
      # with no timeout: ffmpeg transcodes in bursts, and pausing
      # between bursts is normal.  A true playback stall is detected
      # by the frontend watchdog (video element buffer ran dry), not
      # by a backend idle timer that cannot distinguish a pause from
      # a stall.
      begin
        loop do
          unless produced_output
            readable = IO.select([ rd ], nil, nil, FIRST_DATA_TIMEOUT_SECONDS)
            if readable.nil?
              raise TranscodeError, "FFmpeg timed out after #{FIRST_DATA_TIMEOUT_SECONDS}s waiting for first data. #{stderr_summary(stderr_buf)}"
            end
          end

          chunk = rd.readpartial(32_768)
          yield chunk
          total_bytes += chunk.bytesize
          produced_output = true
        end
      rescue EOFError
        # ffmpeg closed stdout.  If it never produced any data, it failed
        # to open or decode the input — surface the stderr diagnostic.
        unless produced_output
          raise TranscodeError, "FFmpeg exited without producing output. #{stderr_summary(stderr_buf)}"
        end
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      rate_kbps = elapsed.positive? ? (total_bytes * 8 / 1000.0 / elapsed).round : 0
      Rails.logger.info("[Transcode] ffmpeg finished: #{total_bytes} bytes in #{elapsed.round(1)}s (#{rate_kbps} kbps)") if defined?(Rails)
    ensure
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
    if packet_subtitles.ok? || packet_subtitles.empty_window?
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

    result = capture_command(cmd, timeout_seconds: subtitle_packet_timeout_seconds(track))
    return subtitle_result(:empty_window, source: :ffprobe_packets, diagnostic: "ffprobe packet extraction timed out") if result.timed_out
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

  def self.build_ffmpeg_command(input_url, headers: {}, start_seconds: 0, audio_stream: nil, subtitle_stream: nil, default_language: nil, preferred_languages: [])
    header_str = ffmpeg_headers(headers)
    video_stream = probe_video_stream(input_url, headers: headers)
    selected_audio_index = selected_audio_stream_index(
      input_url,
      headers: headers,
      audio_stream: audio_stream,
      default_language: default_language,
      preferred_languages: preferred_languages
    )
    selected_burn_subtitle_track = selected_burn_subtitle_track(input_url, headers: headers, subtitle_stream: subtitle_stream)
    video_args = if selected_burn_subtitle_track
      transcode_args
    elsif browser_safe_video?(video_stream)
      [ "-c:v", "copy" ]
    else
      [ "-vf", SAFE_VIDEO_FILTER, *transcode_args ]
    end

    if defined?(Rails)
      encoder = video_args.each_cons(2).find { |k, _| k == "-c:v" }&.last || "copy"
      Rails.logger.info("[Transcode] codec=#{video_stream[:codec_name]} #{video_stream[:width]}x#{video_stream[:height]} encoder=#{encoder}")
    end

    cmd = [ FFMPEG_PATH, "-loglevel", "error" ]
    # Moderate probe limits -- enough for MKV and MPEG-TS (M2TS).
    # M2TS needs more data than MKV because PAT/PMT tables are
    # interleaved every ~100ms in 188-byte packets. 32K was too
    # small and caused ffmpeg to hang on M2TS files. 5M (default)
    # is too much for large remote files. 1M is the sweet spot.
    cmd += [ "-analyzeduration", "1000000", "-probesize", "1000000" ]
    cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
    # Input seeking (before -i): fast, uses the container's seek table.
    seek_start_seconds = normalized_start_seconds(start_seconds)
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
    cmd += [ "-c:a", "aac", "-b:a", "192k", "-ac", "2" ]
    cmd += [
      "-f", "mp4",
      "-movflags", FMP4_FLAGS,
      "-frag_duration", "100000",  # 0.1s for fast first fragment
      "-fflags", "+genpts",
      "pipe:1"
    ]
    cmd
  end
  private_class_method :build_ffmpeg_command

  # Return the best available H.264 encoder args.  On macOS with
  # VideoToolbox, use hardware encoding (h264_videotoolbox) which is
  # ~2x faster than software libx264, keeping the transcode ahead of
  # real-time even for 4K HEVC sources.  Fall back to libx264
  # ultrafast on platforms without VideoToolbox.
  def self.transcode_args
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

  def self.selected_audio_stream_index(input_url, headers:, audio_stream:, default_language:, preferred_languages:)
    explicit_stream_index = normalized_stream_index(audio_stream)
    tracks = probe_media_tracks(input_url, headers: headers)[:audio]

    if explicit_stream_index && tracks.any? { |track| track[:index] == explicit_stream_index }
      return explicit_stream_index
    end

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
      "-show_entries", "stream=codec_name,width,height,pix_fmt",
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
  private_class_method :probe_video_stream

  def self.extract_video_stream(output)
    data = JSON.parse(output)
    stream = Array(data["streams"]).first || {}
    {
      codec_name: stream["codec_name"].to_s.downcase,
      width: positive_integer(stream["width"]),
      height: positive_integer(stream["height"]),
      pix_fmt: stream["pix_fmt"].to_s.downcase
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
      SAFE_H264_PIXEL_FORMATS.include?(pix_fmt)
  end
  private_class_method :browser_safe_video?

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

  def self.subtitle_packet_timeout_seconds(track)
    title = track[:title].to_s.downcase
    return FORCED_SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS if title.include?("forced")

    SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS
  end
  private_class_method :subtitle_packet_timeout_seconds

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

  def self.cache_get(url)
    entry = @probe_cache[url]
    return nil unless entry
    if Time.now > entry[:expires_at]
      @probe_cache.delete(url)
      return nil
    end
    entry
  end
  private_class_method :cache_get

  def self.cache_store(url, **fields)
    while @probe_cache.size >= PROBE_CACHE_MAX_SIZE
      oldest_key = @probe_cache.min_by { |_, entry| entry[:expires_at] }&.first
      break unless oldest_key
      @probe_cache.delete(oldest_key)
    end
    existing = @probe_cache[url] || { expires_at: Time.now + PROBE_CACHE_TTL }
    @probe_cache[url] = existing.merge(fields).merge(expires_at: Time.now + PROBE_CACHE_TTL)
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
    return unless signaled  # ESRCH → already gone

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
