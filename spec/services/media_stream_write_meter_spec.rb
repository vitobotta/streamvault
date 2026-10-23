require "rails_helper"

RSpec.describe Media::StreamWriteMeter do
  let(:now) { [ 1000.0 ] }
  let(:clock) { -> { now.first } }
  subject(:meter) { described_class.new(heartbeat_seconds: 30, clock: clock) }

  def advance(seconds)
    now[0] += seconds
  end

  it "reports written bytes and write cadence in the summary" do
    meter.record(1024)
    advance(2)
    meter.record(2048)

    expect(meter.summary).to include(
      written_bytes: 3072,
      write_count: 2,
      idle_ms_since_last_write: 0,
      max_write_gap_ms: 2000
    )
  end

  it "tracks the largest write gap, not the last one" do
    meter.record(10)
    advance(45)
    meter.record(10)
    advance(1)
    meter.record(10)

    expect(meter.summary[:max_write_gap_ms]).to eq(45_000)
    expect(meter.summary[:idle_ms_since_last_write]).to eq(0)
  end

  it "reports the idle time since the last accepted write" do
    meter.record(512)
    advance(60)

    expect(meter.summary[:idle_ms_since_last_write]).to eq(60_000)
  end

  it "emits a heartbeat once per interval with the window rate" do
    expect(meter.record(1024)).to be_nil
    advance(15)
    expect(meter.record(1024)).to be_nil
    advance(15)

    heartbeat = meter.record(2048)

    expect(heartbeat).to include(
      window_ms: 30_000,
      window_bytes: 4096,
      write_gap_ms: 15_000,
      written_bytes: 4096
    )
    expect(heartbeat[:rate_kbps]).to be_within(0.2).of(0.1)
  end

  it "restarts the heartbeat window after each heartbeat" do
    expect(meter.record(100)).to be_nil
    advance(30)
    expect(meter.record(100)).not_to be_nil
    advance(5)
    expect(meter.record(100)).to be_nil
    advance(25)
    expect(meter.record(100)).to include(window_bytes: 200)
  end
end
