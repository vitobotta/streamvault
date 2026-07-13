# frozen_string_literal: true

require "fileutils"
require "securerandom"

# Manages HLS transcoding sessions for iOS Safari playback.
#
# Session metadata is persisted in hls_sessions so any Puma worker or
# Dokku process can serve playlist and segment requests. The spawning
# worker retains the full ffmpeg process handle, including stderr
# diagnostics, until exit. Activity-based expiry protects active
# sessions while an absolute lifetime bounds abandoned sessions.
#
# Thread-safe: the in-memory process registry uses a mutex. DB operations
# go through ActiveRecord's own connection pool.
class HlsSession
  SESSION_IDLE_TTL = 30.minutes
  MAX_SESSION_LIFETIME = 12.hours
  ACTIVITY_TOUCH_INTERVAL = 1.minute
  SEGMENTS_BEHIND_PLAYHEAD = 6
  SHUTDOWN_GRACE_SECONDS = 1
  ERROR_CACHE_TTL = 5.minutes

  # The worker that spawned ffmpeg retains the complete process handle,
  # including stderr diagnostics, until the process exits or is stopped.
  @processes = {}
  @mutex = Mutex.new

  attr_reader :id, :pid, :segment_dir, :user_id

  def self.create(user_id:, input_url:, headers:, start_seconds:, audio_stream:, subtitle_stream:, default_language:, preferred_languages:)
    session_id = SecureRandom.hex(16)
    dir = Rails.root.join("tmp", "hls", session_id).to_s
    process = TranscodeService.transcode_to_hls(
      input_url,
      segment_dir: dir,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages,
      wait_for_first_segment: false,
      telemetry_id: session_id
    )

    @mutex.synchronize { @processes[session_id] = process }
    HlsSessionRecord.create!(
      user_id: user_id,
      session_id: session_id,
      segment_dir: dir,
      pid: process.pid
    )
    monitor_process(session_id, process)

    new(id: session_id, pid: process.pid, segment_dir: dir, user_id: user_id)
  rescue StandardError
    @mutex.synchronize { @processes.delete(session_id) } if session_id
    HlsSessionKiller.new(process.pid).kill if process
    process&.close_diagnostics
    FileUtils.rm_rf(dir) if dir
    raise
  end

  def self.find(id)
    record = HlsSessionRecord.find_by(session_id: id)
    return nil unless record

    if inactive?(record) || record.created_at < MAX_SESSION_LIFETIME.ago
      stop(id)
      return nil
    end

    touch_activity(record)
    process = @mutex.synchronize { @processes[id] }
    new(
      id: record.session_id,
      pid: process&.pid || record.pid,
      segment_dir: record.segment_dir,
      user_id: record.user_id
    )
  end

  def self.error(id)
    Rails.cache.read(error_cache_key(id))
  end

  def self.set_error(id, message)
    Rails.cache.write(error_cache_key(id), message, expires_in: ERROR_CACHE_TTL)
  end

  def self.error_cache_key(id)
    "hls_session/error/#{id}"
  end

  def self.stop(id)
    record = HlsSessionRecord.find_by(session_id: id)
    process = @mutex.synchronize { @processes.delete(id) }
    return unless record || process

    pid = process&.pid || record&.pid
    HlsSessionKiller.new(pid).kill if pid
    process&.close_diagnostics
    FileUtils.rm_rf(record.segment_dir) if record
    record&.destroy!
    Rails.cache.delete(error_cache_key(id))
  rescue ActiveRecord::RecordNotFound
    # Another request or cleanup worker already stopped the session.
  end

  def self.cleanup_expired
    HlsSessionRecord.where(
      "updated_at < :idle_cutoff OR created_at < :absolute_cutoff",
      idle_cutoff: SESSION_IDLE_TTL.ago,
      absolute_cutoff: MAX_SESSION_LIFETIME.ago
    ).find_each { |record| stop(record.session_id) }

    cleanup_orphan_directories
  end

  def self.cleanup_orphan_directories
    root = Rails.root.join("tmp", "hls")
    return unless root.directory?

    active = HlsSessionRecord.pluck(:segment_dir).to_h { |dir| [ File.expand_path(dir), true ] }
    cutoff = SESSION_IDLE_TTL.ago
    root.children.each do |path|
      next unless path.directory?
      next if active[File.expand_path(path.to_s)]
      next if File.mtime(path) >= cutoff

      FileUtils.rm_rf(path)
    rescue Errno::ENOENT
      # Concurrent cleanup already removed it.
    end
  end

  def self.monitor_process(session_id, process)
    thread = Thread.new do
      status = nil
      begin
        _, status = Process.waitpid2(process.pid)
      rescue Errno::ECHILD, Errno::ESRCH
      ensure
        process.close_diagnostics
      end

      if status && !status.success?
        diagnostic = process.diagnostic.strip
        message = "FFmpeg exited (status #{status.exitstatus})"
        message = "#{message}. stderr: #{diagnostic}" if diagnostic.present?
        set_error(session_id, message)
      end

      @mutex.synchronize do
        @processes.delete(session_id) if @processes[session_id].equal?(process)
      end
      HlsSessionRecord.where(session_id: session_id, pid: process.pid).update_all(pid: nil)
    end
    thread.abort_on_exception = false
  end
  private_class_method :monitor_process

  def self.inactive?(record)
    record.updated_at < SESSION_IDLE_TTL.ago
  end
  private_class_method :inactive?

  def self.touch_activity(record)
    return if record.updated_at >= ACTIVITY_TOUCH_INTERVAL.ago

    record.update_column(:updated_at, Time.current)
  end
  private_class_method :touch_activity

  def playlist_path
    File.join(segment_dir, "playlist.m3u8")
  end

  def segment_path(index)
    File.join(segment_dir, "#{index}.ts")
  end

  def playlist_ready?
    return false unless File.exist?(playlist_path)

    content = File.read(playlist_path)
    content.include?("#EXTINF") || content.include?("#EXT-X-ENDLIST")
  rescue StandardError
    false
  end

  # FFmpeg is paced at realtime after its initial burst.  Delete only
  # segments safely behind the segment Safari has actually requested;
  # never delete future media merely because the producer is fast.
  def prune_consumed_segments(current_index)
    delete_before = current_index.to_i - SEGMENTS_BEHIND_PLAYHEAD
    return if delete_before <= 0

    Dir.glob(File.join(segment_dir, "[0-9]*.ts")).each do |path|
      index = File.basename(path, ".ts").to_i
      File.delete(path) if index < delete_before
    rescue Errno::ENOENT
      # A concurrent segment request already pruned it.
    end
  end

  private

  def initialize(id:, pid:, segment_dir:, user_id:)
    @id = id
    @pid = pid
    @segment_dir = segment_dir
    @user_id = user_id
  end
end

# Helper class to kill an ffmpeg process group.
class HlsSessionKiller
  def initialize(pid)
    @pid = pid
  end

  def kill
    return if @pid.nil?

    signal_group("CONT")
    signaled = signal_group("TERM")
    unless signaled
      waitpid_safely
      return
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HlsSession::SHUTDOWN_GRACE_SECONDS
    while group_alive?
      reap_exited_leader
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end

    signal_group("KILL") if group_alive?
    waitpid_safely
  end

  private

  def signal_group(sig)
    Process.kill(sig, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def group_alive?
    Process.kill(0, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def reap_exited_leader
    Process.waitpid2(@pid, Process::WNOHANG)
  rescue Errno::ESRCH, Errno::ECHILD
  end

  def waitpid_safely
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
  end
end
