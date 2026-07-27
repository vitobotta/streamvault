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
class HlsSessionManager
  SESSION_IDLE_TTL = 30.minutes
  MAX_SESSION_LIFETIME = 12.hours
  ACTIVITY_TOUCH_INTERVAL = 1.minute

  @processes = {}
  @mutex = Mutex.new

  def self.create(user_id:, input_url:, headers:, start_seconds:, audio_stream:, subtitle_stream:, default_language:, preferred_languages:)
    session_id = SecureRandom.hex(16)
    record = HlsSession.create!(user_id: user_id, session_id: session_id)
    dir = record.storage_path
    process = Media::Transcoder.transcode_to_hls(
      input_url,
      segment_dir: dir.to_s,
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
    record.update!(pid: process.pid)
    monitor_process(session_id, process)
    record
  rescue StandardError
    @mutex.synchronize { @processes.delete(session_id) } if session_id
    Media::ProcessManager.kill_group(process.pid) if process
    process&.close_diagnostics
    FileUtils.rm_rf(dir) if dir
    record&.destroy!
    raise
  end

  def self.find(session_id)
    record = HlsSession.find_by(session_id: session_id)
    return unless record

    if inactive?(record) || record.created_at < MAX_SESSION_LIFETIME.ago
      stop(session_id)
      return
    end

    touch_activity(record)
    record
  end

  def self.error(session_id)
    HlsSession.where(session_id: session_id).pick(:error_message)
  end

  def self.set_error(session_id, message)
    HlsSession.where(session_id: session_id).update_all(error_message: message)
  end

  def self.stop(session_id)
    record = HlsSession.find_by(session_id: session_id)
    process = @mutex.synchronize { @processes.delete(session_id) }
    return unless record || process

    pid = process&.pid || record&.pid
    Media::ProcessManager.kill_group(pid) if pid
    process&.close_diagnostics
    FileUtils.rm_rf(record.storage_path) if record
    record&.destroy!
  rescue ActiveRecord::RecordNotFound
    # Another request or cleanup worker already stopped the session.
  end

  def self.cleanup_expired
    HlsSession.where(
      "updated_at < :idle_cutoff OR created_at < :absolute_cutoff",
      idle_cutoff: SESSION_IDLE_TTL.ago,
      absolute_cutoff: MAX_SESSION_LIFETIME.ago
    ).find_each { |record| stop(record.session_id) }

    cleanup_orphan_directories
  end

  def self.cleanup_orphan_directories
    root = HlsSession::HLS_ROOT
    return unless root.directory?

    active = HlsSession.ids.to_h { |id| [ HlsSession.storage_path(id).expand_path.to_s, true ] }
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
      HlsSession.where(session_id: session_id, pid: process.pid).update_all(pid: nil)
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
end
