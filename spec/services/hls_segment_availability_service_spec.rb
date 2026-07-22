require "rails_helper"

RSpec.describe HlsSegmentAvailabilityService do
  let(:session) { instance_double(HlsSession, segment_path: "/segments/3.ts", playlist_path: "/segments/playlist.m3u8") }
  let(:file_system) { class_double(File) }
  let(:error_lookup) { -> { nil } }

  def service(wait_seconds: 0)
    described_class.new(
      session,
      session_id: "session-1",
      wait_seconds: wait_seconds,
      file_system: file_system,
      error_lookup: error_lookup
    )
  end

  it "returns ready when the segment already exists" do
    allow(file_system).to receive(:exist?).with("/segments/3.ts").and_return(true)

    result = service.call(3)

    expect(result.status).to eq(:ready)
    expect(result.path).to eq("/segments/3.ts")
  end

  it "returns finished when an ended playlist lacks the segment" do
    allow(file_system).to receive(:exist?).with("/segments/3.ts").and_return(false)
    allow(file_system).to receive(:exist?).with("/segments/playlist.m3u8").and_return(true)
    allow(file_system).to receive(:read).and_return("#EXTM3U\n#EXT-X-ENDLIST\n")

    expect(service.call(3).status).to eq(:finished)
  end

  it "returns pending when a live stream has not produced the segment before the deadline" do
    allow(file_system).to receive(:exist?).with("/segments/3.ts").and_return(false)
    allow(file_system).to receive(:exist?).with("/segments/playlist.m3u8").and_return(true)
    allow(file_system).to receive(:read).and_return("#EXTM3U\n")

    expect(service.call(3).status).to eq(:pending)
  end

  it "returns the transcoder error without waiting" do
    service = described_class.new(
      session,
      session_id: "session-1",
      file_system: file_system,
      error_lookup: -> { "ffmpeg failed" }
    )

    result = service.call(3)

    expect(result.status).to eq(:failed)
    expect(result.error).to eq("ffmpeg failed")
  end
end
