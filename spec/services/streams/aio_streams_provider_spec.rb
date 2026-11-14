require "rails_helper"

RSpec.describe Streams::AioStreamsProvider do
  let(:base_url) { "https://aiostreams.example.com/stremio/test-uuid" }

  around do |example|
    previous = ENV["AIOSTREAMS_URL"]
    ENV["AIOSTREAMS_URL"] = base_url
    example.run
  ensure
    previous.nil? ? ENV.delete("AIOSTREAMS_URL") : ENV["AIOSTREAMS_URL"] = previous
  end

  it "normalizes a manifest install link to the addon base" do
    ENV["AIOSTREAMS_URL"] = "#{base_url}/manifest.json"
    expect(described_class.base_url).to eq(base_url)
  end

  it "normalizes an install link that ends in a trailing slash" do
    ENV["AIOSTREAMS_URL"] = "#{base_url}/manifest.json/"
    expect(described_class.base_url).to eq(base_url)
  end

  it "normalizes a bare addon base with a trailing slash" do
    ENV["AIOSTREAMS_URL"] = "#{base_url}/"
    expect(described_class.base_url).to eq(base_url)
  end

  it "reports missing configuration instead of calling a blank URL" do
    ENV.delete("AIOSTREAMS_URL")

    result = described_class.new.streams("tt1375666", "movie")

    expect(result).to be_failure
    expect(result.error_message).to include("not configured")
  end

  it "requests the Stremio stream path and parses the streams" do
    body = {
      "streams" => [
        {
          "name" => "[TB⚡] AIOStreams 4K",
          "description" => "📄 Inception.2160p.mkv\n💾 50.4 GB",
          "url" => "https://aiostreams.example.com/api/v1/proxy/abc",
          "behaviorHints" => {
            "filename" => "Inception.2160p.mkv",
            "videoSize" => 54_000_000_000,
            "bingeGroup" => "aiostreams|torbox|abc123"
          }
        }
      ]
    }
    stub_request(:get, "#{base_url}/stream/movie/tt1375666.json")
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

    result = described_class.new.streams("tt1375666", "movie", preferred_languages: [ "ENG" ], default_language: "ENG")

    expect(result).to be_success
    stream = result.data.first
    expect(stream.filename).to eq("Inception.2160p.mkv")
    expect(stream.resolve_url).to eq("https://aiostreams.example.com/api/v1/proxy/abc")
    expect(stream.info_hash).to eq("abc123")
    expect(stream.raw_size).to eq(54_000_000_000)
  end

  it "requests the series path with season and episode coordinates" do
    stub_request(:get, "#{base_url}/stream/series/tt0903747:1:2.json")
      .to_return(status: 200, body: { "streams" => [] }.to_json,
                 headers: { "Content-Type" => "application/json" })

    result = described_class.new.streams("tt0903747", "show", season: 1, episode: 2)

    expect(result).to be_success
    expect(result.data).to eq([])
  end

  it "refuses a series request without coordinates instead of asking for a movie" do
    result = described_class.new.streams("tt0903747", "show")

    expect(result).to be_failure
    expect(result.error_message).to include("Season and episode")
  end

  it "treats 404 as an empty result" do
    stub_request(:get, "#{base_url}/stream/movie/tt9999999.json").to_return(status: 404)

    result = described_class.new.streams("tt9999999", "movie")

    expect(result).to be_success
    expect(result.data).to eq([])
  end
end
