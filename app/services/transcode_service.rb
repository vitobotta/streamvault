# frozen_string_literal: true

require "open3"
require "timeout"
require "json"

# Remuxes/transcodes streams via FFmpeg for browser playback.
# Browser-safe H.264 video is copied; risky/unsupported video is
# normalized to 1080p H.264. Audio is always transcoded to AAC.
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
  SHUTDOWN_GRACE_SECONDS = 3
  STDERR_MAX_BYTES = 8192
  MIN_VALID_DURATION_SECONDS = 60
  MAX_VALID_DURATION_SECONDS = 24 * 60 * 60
  MAX_COPY_VIDEO_WIDTH = 1920
  MAX_COPY_VIDEO_HEIGHT = 1080
  SAFE_VIDEO_FILTER =
    "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p"
  VIDEO_TRANSCODE_ARGS = [
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-crf", "23",
    "-profile:v", "high",
    "-pix_fmt", "yuv420p"
  ].freeze
  SAFE_H264_PIXEL_FORMATS = %w[yuv420p].freeze
  # Cache probe results to avoid repeated ffprobe round-trips for the same URL.
  # Key: input_url, Value: { duration:, video_stream:, expires_at: }
  @probe_cache = {}
  PROBE_CACHE_TTL = 300 # 5 minutes

  class TranscodeError < StandardError; end


  # Stream transcoded/remuxed fMP4 from FFmpeg.
  # Copies video only when the source is already browser-safe H.264 at
  # 1080p or below. UHD/HEVC/remux sources are transcoded so the browser
  # is not asked to decode crash-prone streams directly.
  #
  # Accepts optional headers hash for auth and start_seconds for seeking.
  #
  # Raises TranscodeError if ffmpeg exits before producing any output
  # (bad URL, auth failure, expired link).  When the caller stops reading
  # (client disconnect → exception propagates through the yield), the
  # ensure block kills ffmpeg.
  def self.transcode_to_fmp4(input_url, headers: {}, start_seconds: 0, &block)
    cmd = build_ffmpeg_command(input_url, headers: headers, start_seconds: start_seconds)

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

      # readpartial returns whatever data is available (up to 32 KB)
      # without waiting for the full amount, then blocks for more.
      # When ffmpeg closes stdout (exit), it raises EOFError.
      begin
        loop do
          chunk = rd.readpartial(32_768)
          yield chunk
          produced_output = true
        end
      rescue EOFError
        # ffmpeg closed stdout.  If it never produced any data, it failed
        # to open or decode the input — surface the stderr diagnostic.
        unless produced_output
          raise TranscodeError, "FFmpeg exited without producing output. #{stderr_summary(stderr_buf)}"
        end
      end
    ensure
      kill_process_group(pid)
      stderr_thread.kill
      stderr_thread.join(1)
      rd.close
      err_rd.close
    end
  end

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

    stdout, _, status = Timeout.timeout(10) { Open3.capture3(*cmd) }
    return 0 unless status.success?

    duration = extract_probe_duration(stdout)
    cache_store(input_url, duration: duration)
    duration
  rescue Timeout::Error, StandardError
    0
  end

  def self.build_ffmpeg_command(input_url, headers: {}, start_seconds: 0)
    header_str = ffmpeg_headers(headers)
    video_stream = probe_video_stream(input_url, headers: headers)
    video_args = browser_safe_video?(video_stream) ? [ "-c:v", "copy" ] : [ "-vf", SAFE_VIDEO_FILTER, *VIDEO_TRANSCODE_ARGS ]

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
    cmd += [ "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn" ]
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

    stdout, _, status = Timeout.timeout(10) { Open3.capture3(*cmd) }
    stream = status.success? ? extract_video_stream(stdout) : {}
    cache_store(input_url, video_stream: stream)
    stream
  rescue Timeout::Error, StandardError
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
    integer = value.to_i
    integer.positive? ? integer : nil
  end
  private_class_method :positive_integer

  def self.normalized_start_seconds(value)
    seconds = value.to_f
    seconds.finite? && seconds.positive? ? seconds : 0
  end
  private_class_method :normalized_start_seconds

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
    until reaped?(pid)
      return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
    end

    # Still alive — force kill
    signal_group(pid, "KILL")
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
