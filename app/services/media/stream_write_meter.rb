# frozen_string_literal: true

module Media
  # Tracks the write cadence of a long-lived streaming response.
  #
  # A stream can end in two very different ways that look identical in the
  # existing log line: the writer was idle long enough for a proxy to time
  # the response out, or the socket was closed while data was still
  # flowing. The gap since the last successful write at the moment of
  # failure separates them, and a periodic heartbeat records the flow even
  # when nothing fails.
  class StreamWriteMeter
    DEFAULT_HEARTBEAT_SECONDS = 30

    def initialize(heartbeat_seconds: DEFAULT_HEARTBEAT_SECONDS, clock: nil)
      @heartbeat_seconds = heartbeat_seconds.to_f
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @started_at = @clock.call
      @last_write_at = @started_at
      @last_heartbeat_at = @started_at
      @written_bytes = 0
      @write_count = 0
      @bytes_since_heartbeat = 0
      @max_write_gap_ms = 0
    end

    # Records a chunk that the response accepted. Returns a heartbeat hash
    # when the interval elapsed, otherwise nil.
    def record(bytes)
      size = bytes.to_i
      now = @clock.call
      gap_ms = ((now - @last_write_at) * 1000).round
      @max_write_gap_ms = gap_ms if gap_ms > @max_write_gap_ms
      @last_write_at = now
      @written_bytes += size
      @write_count += 1
      @bytes_since_heartbeat += size

      elapsed = now - @last_heartbeat_at
      return nil if elapsed < @heartbeat_seconds

      heartbeat = {
        window_ms: (elapsed * 1000).round,
        window_bytes: @bytes_since_heartbeat,
        rate_kbps: rate_kbps(@bytes_since_heartbeat, elapsed),
        write_gap_ms: gap_ms.to_i,
        written_bytes: @written_bytes
      }
      @last_heartbeat_at = now
      @bytes_since_heartbeat = 0
      heartbeat
    end

    def summary
      now = @clock.call
      {
        elapsed_ms: ((now - @started_at) * 1000).round,
        written_bytes: @written_bytes,
        write_count: @write_count,
        idle_ms_since_last_write: ((now - @last_write_at) * 1000).round,
        max_write_gap_ms: @max_write_gap_ms
      }
    end

    private

    def rate_kbps(bytes, seconds)
      return 0 if seconds <= 0

      (bytes / 1024.0 / seconds).round(1)
    end
  end
end
