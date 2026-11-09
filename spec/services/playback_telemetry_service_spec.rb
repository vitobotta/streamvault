require "rails_helper"

RSpec.describe PlaybackTelemetryService do
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil) }
  subject(:service) { described_class.new(logger: logger) }

  it "sanitizes and bounds client-controlled telemetry before logging" do
    payload = service.record(
      user_id: 42,
      attributes: {
        event: "stall\nforged",
        playback_id: "playback-1",
        path: "mse_transcode",
        position: "12.345",
        current_time: "7.5",
        seeking: true,
        baseline_position: "509.25",
        baseline_age_ms: "20004",
        fetch_error: "TypeError",
        buffer_ahead: "Infinity",
        recovery_count: 101,
        ready_state: 9,
        network_state: -1,
        paused: "true",
        mse_pending_bytes: 2.gigabytes,
        buffered_ranges: [ [ 1.234, 5.678 ], [ "bad", nil ] ]
      }
    )

    expect(payload).to include(
      event: "stall forged",
      position: 12.35,
      current_time: 7.5,
      seeking: true,
      baseline_position: 509.25,
      baseline_age_ms: 20_004,
      fetch_error: "TypeError",
      buffer_ahead: 0,
      recovery_count: 100,
      ready_state: 4,
      network_state: 0,
      paused: true,
      mse_pending_bytes: 1.gigabyte,
      buffered_ranges: [ [ 1.23, 5.68 ], [ 0, 0 ] ],
      user_id: 42
    )
    expect(logger).to have_received(:info).with(start_with("[StallTelemetry] "))
  end

  it "keeps at most eight valid buffered ranges" do
    ranges = 10.times.map { |index| [ index, index + 1 ] } + [ { invalid: true } ]

    payload = service.record(user_id: 1, attributes: { buffered_ranges: ranges })

    expect(payload[:buffered_ranges].length).to eq(8)
  end

  it "logs the stall counters that attribute a pause to its cause" do
    payload = service.record(
      user_id: 7,
      attributes: {
        event: "rebuffer_begin",
        fetch_error_message: "network\nerror while reading",
        first_chunk: "false",
        last_chunk_age_ms: "4321",
        bytes_read: 12.gigabytes,
        stream_age_ms: "61000",
        read_paused_ms: "15000",
        read_pause_count: "4",
        evictions_count: "2",
        evicted_seconds_total: "62.25",
        last_eviction_age_ms: "-1",
        ahead_at_begin: "0.4",
        ahead_at_end: "12.5",
        had_buffered_ahead: "false",
        duration_ms: "1500",
        deadline_fired: "true",
        cushion_seconds: "27.5",
        failure_age_ms: "21000",
        removed_seconds: "31",
        kind: "back"
      }
    )

    expect(payload).to include(
      fetch_error_message: "network error while reading",
      first_chunk: false,
      last_chunk_age_ms: 4_321,
      bytes_read: 4.gigabytes,
      stream_age_ms: 61_000,
      read_paused_ms: 15_000,
      read_pause_count: 4,
      evictions_count: 2,
      evicted_seconds_total: 62.25,
      last_eviction_age_ms: -1,
      ahead_at_begin: 0.4,
      ahead_at_end: 12.5,
      had_buffered_ahead: false,
      duration_ms: 1_500,
      deadline_fired: true,
      cushion_seconds: 27.5,
      failure_age_ms: 21_000,
      removed_seconds: 31,
      eviction_kind: "back"
    )
  end
end
