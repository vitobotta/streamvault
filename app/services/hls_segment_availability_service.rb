# frozen_string_literal: true

class HlsSegmentAvailabilityService
  Result = Struct.new(:status, :path, :error, keyword_init: true)
  DEFAULT_WAIT_SECONDS = Rails.env.test? ? 1 : 10
  DEFAULT_POLL_INTERVAL = 0.3

  def initialize(
    session,
    session_id:,
    wait_seconds: DEFAULT_WAIT_SECONDS,
    poll_interval: DEFAULT_POLL_INTERVAL,
    file_system: File,
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
    sleeper: ->(seconds) { sleep(seconds) },
    error_lookup: -> { HlsSessionManager.error(session_id) }
  )
    @session = session
    @wait_seconds = wait_seconds
    @poll_interval = poll_interval
    @file_system = file_system
    @clock = clock
    @sleeper = sleeper
    @error_lookup = error_lookup
  end

  def call(segment_index)
    path = @session.segment_path(segment_index)
    error = @error_lookup.call
    return Result.new(status: :failed, path: path, error: error) if error
    return Result.new(status: :ready, path: path) if @file_system.exist?(path)
    return Result.new(status: :finished, path: path) if ffmpeg_finished?

    deadline = @clock.call + @wait_seconds
    while @clock.call < deadline
      @sleeper.call(@poll_interval)
      return Result.new(status: :ready, path: path) if @file_system.exist?(path)

      break if ffmpeg_finished?
      error = @error_lookup.call
      return Result.new(status: :failed, path: path, error: error) if error
    end

    error = @error_lookup.call
    return Result.new(status: :failed, path: path, error: error) if error
    return Result.new(status: :ready, path: path) if @file_system.exist?(path)

    Result.new(status: :pending, path: path)
  end

  private

  def ffmpeg_finished?
    playlist_path = @session.playlist_path
    return false unless @file_system.exist?(playlist_path)

    @file_system.read(playlist_path).include?("#EXT-X-ENDLIST")
  rescue StandardError
    false
  end
end
