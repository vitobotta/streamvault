require "rails_helper"

RSpec.describe ResolvedSource do
  let(:user) { build(:user, realdebrid_api_key: "own_rd_key") }

  around do |example|
    previous = { "AIOSTREAMS_URL" => ENV["AIOSTREAMS_URL"], "COMET_URL" => ENV["COMET_URL"], "STREAM_SOURCE_HOSTS" => ENV["STREAM_SOURCE_HOSTS"] }
    ENV.delete("AIOSTREAMS_URL")
    ENV.delete("COMET_URL")
    ENV.delete("STREAM_SOURCE_HOSTS")
    example.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "infers RealDebrid and sends the account bearer token" do
    source = described_class.new(url: "https://download.real-debrid.com/d/file/video.mp4")

    expect(source.service).to eq("realdebrid")
    expect(source.request_headers(user)).to eq("Authorization" => "Bearer own_rd_key")
  end

  it "accepts TorBox CDN hosts and never sends the RealDebrid token there" do
    source = described_class.new(url: "https://store-1.torbox.app/file/video.mp4")

    expect(source.service).to eq("torbox")
    expect(source.request_headers(user)).to eq({})
  end

  it "accepts a configured AIOStreams host without leaking a debrid key" do
    ENV["AIOSTREAMS_URL"] = "https://aiostreams.example.com/stremio/uuid"
    source = described_class.new(url: "https://aiostreams.example.com/api/v1/proxy/abc")

    expect(source.service).to be_nil
    expect(source.request_headers(user)).to eq({})
  end

  it "accepts an operator-added source host" do
    ENV["STREAM_SOURCE_HOSTS"] = "stremthru.example.com"

    expect(described_class.new(url: "https://stremthru.example.com/file/video.mp4").service).to be_nil
  end

  it "rejects a host outside the allowlist" do
    expect { described_class.new(url: "https://evil.example/video.mp4") }.to raise_error(described_class::Invalid)
  end

  it "round-trips the service through a signed token" do
    user.save!
    token = described_class.issue(user: user, url: "https://store-1.torbox.app/file/video.mp4")
    resolved = described_class.resolve(token: token, user: user, verify_dns: false)

    expect(resolved.service).to eq("torbox")
  end
end
