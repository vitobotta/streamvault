# frozen_string_literal: true

require "fileutils"
require "securerandom"

# In-memory registry of HLS transcoding sessions for iOS Safari playback.
#
# Each session owns an ffmpeg process (writing .ts segments + playlist.m3u8
# to a temp directory) and a 30-minute TTL.  Sessions are ephemeral — no DB
# row is written; the registry lives in process memory and dies with the
# server.  That is acceptable because iOS Safari re-requests the playlist
# and segments: a server restart simply interrupts the current stream, and
# the player surfaces an error the user can retry.
#
# Thread-safe: all registry mutations go through @mutex.  ffmpeg is killed
# via its process group (negative PID) so helper processes are reaped too.
class HlsSession
  SESSION_TTL = 30.minutes
  CLEANUP_INTERVAL = 5.minutes
  # Grace period before SIGKILL after SIGTERM, matching TranscodeService.
  SHUTDOWN_GRACE_SECONDS = 1

  @sessions = {}
  @mutex = Mutex.new

  attr_reader :id, :pid, :segment_dir, :created_at, :user_id

  # Start a new HLS transcode session.  Spawns ffmpeg (via
  # TranscodeService.transcode_to_hls), which returns once the first
  # segment is on disk.  Returns the new session object.
  def self.create(user_id:, input_url:, headers:, start_seconds:, audio_stream:, subtitle_stream:, default_language:, preferred_languages:)
    session_id = SecureRandom.hex(16)
    dir = Rails.root.join("tmp", "hls", session_id).to_s

    pid = TranscodeService.transcode_to_hls(
      input_url,
      segment_dir: dir,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages
    )

    session = new(id: session_id, pid: pid, segment_dir: dir, user_id: user_id)
    @mutex.synchronize { @sessions[session_id] = session }
    session
  end

  # Look up a session by id.  Returns nil if not found or expired.
  # Expired sessions are stopped as a side effect.
  def self.find(id)
    session = @mutex.synchronize { @sessions[id] }
    return nil unless session

    if session.expired?
      stop(id)
      return nil
    end

    session
  end

  # Stop and remove a session by id.  No-op if not found.
  def self.stop(id)
    session = @mutex.synchronize { @sessions.delete(id) }
    session&.stop
  end

  # Stop all sessions older than SESSION_TTL.  Intended to be called
  # periodically (e.g. a Solid Queue recurring job).
  def self.cleanup_expired
    expired_ids = @mutex.synchronize { @sessions.select { |_id, s| s.expired? }.keys }
    expired_ids.each { |id| stop(id) }
  end

  # Number of active sessions (for diagnostics/monitoring).
  def self.count
    @mutex.synchronize { @sessions.size }
  end

  def playlist_path
    File.join(segment_dir, "playlist.m3u8")
  end

  def segment_path(index)
    File.join(segment_dir, "#{index}.ts")
  end

  def expired?
    Time.now - created_at > SESSION_TTL
  end

  # Kill the ffmpeg process group and delete the segment directory.
  # Safe to call if ffmpeg already exited or the directory is gone.
  def stop
    kill_process_group
    delete_segment_dir
  end

  private

  def initialize(id:, pid:, segment_dir:, user_id:)
    @id = id
    @pid = pid
    @segment_dir = segment_dir
    @user_id = user_id
    @created_at = Time.now
  end

  def kill_process_group
    return if pid.nil?

    # Resume the process if stopped (SIGTTIN/SIGTSTP can stop a background
    # process group member); a stopped process cannot receive TERM/KILL.
    signal_group("CONT")
    signaled = signal_group("TERM")
    return unless signaled  # ESRCH → already gone

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SHUTDOWN_GRACE_SECONDS
    while group_alive?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end

    signal_group("KILL") if group_alive?
    waitpid_safely
  end

  # Send a signal to the process group.  Returns true if delivered,
  # false if the group is already gone.
  def signal_group(sig)
    Process.kill(sig, -pid)  # negative PID → entire process group
    true
  rescue Errno::ESRCH
    false  # already exited
  rescue Errno::EPERM
    # macOS: group leader gone.  Treat as "try reaping" rather than failure.
    true
  end

  def group_alive?
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def waitpid_safely
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already reaped
  end

  def delete_segment_dir
    FileUtils.rm_rf(segment_dir)
  rescue Errno::ENOENT
    # already gone
  end
end
