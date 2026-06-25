require 'rails_helper'

RSpec.describe CometService do
  let(:rd_api_key) { "test_rd_key_123" }
  let(:service) { described_class.new(rd_api_key: rd_api_key) }

  around do |ex|
    original_comet = ENV["COMET_URL"]
    ENV["COMET_URL"] = "http://comet.example.com"
    ex.run
    ENV["COMET_URL"] = original_comet
  end

  describe "#streams" do
    it "returns failure for blank imdb_id" do
      result = service.streams("", "movie")
      expect(result).to be_failure
    end

    it "returns failure when COMET_URL is not configured" do
      ENV["COMET_URL"] = ""
      result = described_class.new(rd_api_key: rd_api_key).streams("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("not configured")
    end

    it "returns streams for a movie" do
      stub_request(:get, %r{comet\.example\.com/[^/]+/stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 1080p [YTS]", "infoHash" => "abc123def", "fileIdx" => 0, "seeders" => 100, "url" => "http://comet.example.com/playback/abc" }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.streams("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data.length).to eq(1)
      expect(result.data.first[:info_hash]).to eq("abc123def")
      expect(result.data.first[:quality]).to eq("1080p")
      expect(result.data.first[:resolve_url]).to eq("http://comet.example.com/playback/abc")
    end

    it "returns streams for a series episode" do
      stub_request(:get, %r{comet\.example\.com/[^/]+/stream/series/tt0903747:1:1\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Breaking Bad S01E01 720p", "infoHash" => "xyz789", "fileIdx" => 0, "seeders" => 50, "url" => "http://comet.example.com/playback/xyz" }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.streams("tt0903747", "show", season: 1, episode: 1)
      expect(result).to be_success
      expect(result.data.first[:quality]).to eq("720p")
    end

    it "returns empty array for 404" do
      stub_request(:get, %r{comet\.example\.com/[^/]+/stream/movie/tt9999999\.json})
        .to_return(status: 404, body: "Not Found")

      result = service.streams("tt9999999", "movie")
      expect(result).to be_success
      expect(result.data).to eq([])
    end

    it "returns failure for non-200 non-404 response" do
      stub_request(:get, %r{comet\.example\.com/[^/]+/stream/movie/tt1375666\.json})
        .to_return(status: 500, body: "Internal Server Error")

      result = service.streams("tt1375666", "movie")
      expect(result).to be_failure
    end
  end

  describe ".resolve_base_url" do
    it "returns the configured COMET_URL" do
      ENV["COMET_URL"] = "http://my-comet:8000"
      expect(described_class.resolve_base_url).to eq("http://my-comet:8000")
    end
  end

  describe "config encoding" do
    it "includes the RD API key in the base64 config path" do
      stub_request(:get, %r{comet\.example\.com/([^/]+)/stream/movie/tt1375666\.json}) do |request|
        config_segment = request.uri.path.split("/")[1]
        decoded = Base64.urlsafe_decode64(config_segment)
        config = JSON.parse(decoded)
        expect(config["debridService"]).to eq("realdebrid")
        expect(config["debridApiKey"]).to eq(rd_api_key)
      end

      service.streams("tt1375666", "movie")
    end
  end
end

RSpec.describe StreamProvider do
  around do |ex|
    original_provider = ENV["STREAM_PROVIDER"]
    original_comet = ENV["COMET_URL"]
    ex.run
    ENV["STREAM_PROVIDER"] = original_provider
    ENV["COMET_URL"] = original_comet
  end

  describe ".providers" do
    it "returns only Torrentio by default" do
      ENV["STREAM_PROVIDER"] = "torrentio"
      ENV["COMET_URL"] = ""
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(TorrentioService)
    end

    it "returns Comet then Torrentio when STREAM_PROVIDER=comet" do
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "http://comet:8000"
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(2)
      expect(providers.first).to be_a(CometService)
      expect(providers.last).to be_a(TorrentioService)
    end

    it "returns Comet then Torrentio when STREAM_PROVIDER=auto and COMET_URL set" do
      ENV["STREAM_PROVIDER"] = "auto"
      ENV["COMET_URL"] = "http://comet:8000"
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(2)
      expect(providers.first).to be_a(CometService)
    end

    it "returns only Torrentio when STREAM_PROVIDER=auto and COMET_URL blank" do
      ENV["STREAM_PROVIDER"] = "auto"
      ENV["COMET_URL"] = ""
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(TorrentioService)
    end
  end

  describe ".resolve_base_urls" do
    it "includes Comet URL when configured" do
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "http://my-comet:8000"
      urls = described_class.resolve_base_urls
      expect(urls).to include("http://my-comet:8000")
      expect(urls).to include("https://torrentio.strem.fun")
    end

    it "returns only torrentio URLs when Comet not configured" do
      ENV["STREAM_PROVIDER"] = "torrentio"
      ENV["COMET_URL"] = ""
      urls = described_class.resolve_base_urls
      expect(urls).to include("https://torrentio.strem.fun")
      expect(urls.any? { |u| u.include?("comet") }).to be false
    end
  end
end
