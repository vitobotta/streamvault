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
end
