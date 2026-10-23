# frozen_string_literal: true

class PlaybackTelemetryService
  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def record(user_id:, attributes:)
    payload = {
      event: sanitize_log_value(attributes[:event], 48),
      playback_id: sanitize_log_value(attributes[:playback_id], 80),
      path: sanitize_log_value(attributes[:path], 32),
      position: finite_log_number(attributes[:position]),
      current_time: finite_log_number(attributes[:current_time]),
      seeking: boolean(attributes[:seeking]),
      baseline_position: finite_log_number(attributes[:baseline_position]),
      baseline_age_ms: bounded_log_integer(attributes[:baseline_age_ms], 0, 86_400_000),
      fetch_error: sanitize_log_value(attributes[:fetch_error], 48),
      fetch_error_message: sanitize_log_value(attributes[:fetch_error_message], 120),
      first_chunk: boolean(attributes[:first_chunk]),
      last_chunk_age_ms: bounded_log_integer(attributes[:last_chunk_age_ms], 0, 86_400_000),
      bytes_read: bounded_log_integer(attributes[:bytes_read], 0, 4.gigabytes),
      stream_age_ms: bounded_log_integer(attributes[:stream_age_ms], 0, 86_400_000),
      read_paused_ms: bounded_log_integer(attributes[:read_paused_ms], 0, 86_400_000),
      read_pause_count: bounded_log_integer(attributes[:read_pause_count], 0, 1_000_000),
      evictions_count: bounded_log_integer(attributes[:evictions_count], 0, 1_000_000),
      evicted_seconds_total: finite_log_number(attributes[:evicted_seconds_total]),
      last_eviction_age_ms: bounded_log_integer(attributes[:last_eviction_age_ms], -1, 86_400_000),
      ahead_at_begin: finite_log_number(attributes[:ahead_at_begin]),
      ahead_at_end: finite_log_number(attributes[:ahead_at_end]),
      had_buffered_ahead: boolean(attributes[:had_buffered_ahead]),
      duration_ms: bounded_log_integer(attributes[:duration_ms], 0, 86_400_000),
      deadline_fired: boolean(attributes[:deadline_fired]),
      cushion_seconds: finite_log_number(attributes[:cushion_seconds]),
      failure_age_ms: bounded_log_integer(attributes[:failure_age_ms], 0, 86_400_000),
      removed_seconds: finite_log_number(attributes[:removed_seconds]),
      eviction_kind: sanitize_log_value(attributes[:kind], 16),
      buffer_ahead: finite_log_number(attributes[:buffer_ahead]),
      recovery_count: bounded_log_integer(attributes[:recovery_count], 0, 100),
      ready_state: bounded_log_integer(attributes[:ready_state], 0, 4),
      network_state: bounded_log_integer(attributes[:network_state], 0, 3),
      paused: boolean(attributes[:paused]),
      ended: boolean(attributes[:ended]),
      mse_pending_bytes: bounded_log_integer(attributes[:mse_pending_bytes], 0, 1.gigabyte),
      mse_quota_errors: bounded_log_integer(attributes[:mse_quota_errors], 0, 10_000),
      system_rebuffer_paused: boolean(attributes[:system_rebuffer_paused]),
      buffered_ranges: sanitized_buffered_ranges(attributes[:buffered_ranges]),
      video_codec: sanitize_log_value(attributes[:video_codec], 24),
      video_width: bounded_log_integer(attributes[:video_width], 0, 16_384),
      video_height: bounded_log_integer(attributes[:video_height], 0, 16_384),
      start_seconds: finite_log_number(attributes[:start_seconds]),
      user_id: user_id
    }

    @logger.info("[StallTelemetry] #{payload.to_json}")
    payload
  end

  private

  def sanitize_log_value(value, max_length)
    value.to_s.gsub(/[\r\n\t]/, " ").first(max_length)
  end

  def finite_log_number(value)
    number = Float(value, exception: false)
    number&.finite? ? number.round(2) : 0
  end

  def bounded_log_integer(value, minimum, maximum)
    value.to_i.clamp(minimum, maximum)
  end

  def boolean(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def sanitized_buffered_ranges(value)
    Array(value).first(8).filter_map do |range|
      next unless range.is_a?(Array) && range.length >= 2

      [ finite_log_number(range[0]), finite_log_number(range[1]) ]
    end
  end
end
