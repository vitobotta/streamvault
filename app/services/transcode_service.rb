# frozen_string_literal: true

require "open3"
require "timeout"

# Remuxes/transcodes streams via FFmpeg for browser playback.
# Video is copied (no re-encoding), audio → AAC.
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
  # Audio codecs that browsers can play in MP4 container without transcoding.
  # If the source audio is one of these, we copy it instead of encoding to AAC.
  BROWSER_COMPATIBLE_AUDIO = %w[aac mp3].freeze
  # Cache probe results to avoid repeated ffprobe round-trips for the same URL.
  # Key: input_url, Value: { codec:, duration:, expires_at: }
  @probe_cache = {}
  PROBE_CACHE_TTL = 300 # 5 minutes

  class TranscodeError < StandardError; end

  # Transcode only when the audio codec isn't browser-compatible.
  # If the source already has AAC or MP3 audio, a pure remux (copy both
  # video and audio) is enough — zero CPU cost, fastest possible path.
  def self.needs_transcode?(filename)
    # We can't know the audio codec from the filename alone, so always
    # return true.  The actual decision happens in transcode_to_fmp4
    # via a probe — if the audio is already AAC/MP3, we copy instead
    # of encode.
    true
  end

  # Stream transcoded/remuxed fMP4 from FFmpeg.
  # Probes the source audio codec first: if it's AAC or MP3 (browser-
  # compatible), copies both video and audio (pure remux, ~0 CPU).
  # Otherwise copies video and transcodes audio → AAC.
  #
  # Accepts optional headers hash for auth and start_seconds for seeking.
  #
  # Raises TranscodeError if ffmpeg exits before producing any output
  # (bad URL, auth failure, expired link).  When the caller stops reading
  # (client disconnect → exception propagates through the yield), the
  # ensure block kills ffmpeg.
  def self.transcode_to_fmp4(input_url, headers: {}, start_seconds: 0, &block)
    header_str = headers.map { |k, v| "#{k}: #{v}" }.join("\r\n")
    audio_codec = probe_audio_codec(input_url, headers: header_str)
    copy_audio = BROWSER_COMPATIBLE_AUDIO.include?(audio_codec)

    if copy_audio
      Rails.logger.info("[Transcode] Pure remux (audio=#{audio_codec}, no encoding)")
    else
      Rails.logger.info("[Transcode] Audio transcode (source=#{audio_codec || "unknown"} → aac)")
    end

    cmd = [FFMPEG_PATH, "-loglevel", "error"]
    # Limit analyze duration to reduce time-to-first-byte for MKV over HTTP.
    # Without this, ffmpeg may buffer 5+ seconds of data before producing output.
    cmd += ["-analyzeduration", "2M", "-probesize", "2M"]
    cmd += ["-headers", header_str + "\r\n"] if header_str.present?
    # Input seeking (before -i): fast, uses the container's seek table.
    # For MKV over HTTP, ffmpeg sends a Range request to approximately
    # the right byte position.  Must be before -i to avoid decoding and
    # discarding frames.
    cmd += ["-ss", start_seconds.to_s] if start_seconds.to_f > 0
    cmd += ["-i", input_url]
    cmd += ["-c:v", "copy"]
    if copy_audio
      cmd += ["-c:a", "copy"]
    else
      cmd += ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
      # Use all available threads for audio encoding (AAC encoder is
      # single-threaded, but this doesn't hurt and helps with future codecs).
      cmd += ["-threads", "0"]
    end
    cmd += [
      "-f", "mp4",
      "-movflags", FMP4_FLAGS,
      # Fragment duration: 0.5s balances time-to-first-byte vs overhead.
      # Smaller fragments start playback faster but have more container
      # overhead; larger fragments are more efficient but delay first frame.
      "-frag_duration", "500000",  # microseconds (0.5s)
      "-fflags", "+genpts",
      "pipe:1"
    ]

    rd, wr = IO.pipe
    err_rd, err_wr = IO.pipe
    pid = Process.spawn(*cmd, in: "/dev/null", out: wr, err: err_wr, pgroup: true)
    wr.close
    err_wr.close

    # Drain stderr in background to:
    # 1. Prevent pipe-buffer deadlock (ffmpeg blocks on stderr write
    #    if the 64 KB kernel buffer fills and we never read it).
    # 2. Capture diagnostics for TranscodeError when ffmpeg fails.
    stderr_buf = +""
    stderr_thread = Thread.new do
      loop { stderr_buf << err_rd.readpartial(4096) }
    rescue EOFError, IOError, Errno::EBADF
      # pipe closed or process killed — thread exits
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
  def self.probe_duration(input_url, headers: {})
    cached = cache_get(input_url)
    return cached[:duration] if cached && cached[:duration]

    header_str = headers.map { |k, v| "#{k}: #{v}" }.join("\r\n")

    cmd = [FFPROBE_PATH, "-v", "error"]
    cmd += ["-headers", header_str + "\r\n"] if header_str.present?
    cmd += ["-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            input_url]

    stdout, _, status = Timeout.timeout(15) { Open3.capture3(*cmd) }
    return 0 unless status.success?

    duration = stdout.strip.to_f
    duration = duration > 0 ? duration : 0
    cache_store(input_url, duration: duration)
    duration
  rescue Timeout::Error, StandardError
    0
  end

  # Probe the audio codec of a stream URL using ffprobe.
  # Returns the codec name (e.g. "aac", "ac3", "truehd") or nil if unknown.
  # Uses the probe cache to avoid repeated ffprobe calls.
  def self.probe_audio_codec(input_url, headers: "")
    cached = cache_get(input_url)
    return cached[:codec] if cached

    cmd = [FFPROBE_PATH, "-v", "error"]
    cmd += ["-headers", headers + "\r\n"] if headers.present?
    cmd += ["-select_streams", "a:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            input_url]

    stdout, _, status = Timeout.timeout(10) { Open3.capture3(*cmd) }
    codec = status.success? ? stdout.strip.downcase : nil
    codec = nil if codec == "unknown" || codec.blank?
    cache_store(input_url, codec: codec)
    codec
  rescue Timeout::Error, StandardError
    nil
  end

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
