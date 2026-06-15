require 'rails_helper'

RSpec.describe ContentStreamingService do
  let(:user) { create(:user, realdebrid_api_key: "test_key_123") }
  subject(:service) { described_class.new(user) }

  let(:cinemeta_stub) {
    stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
      .to_return(
        status: 200,
        body: { "meta" => { "id" => "tt1375666", "name" => "Inception" } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  }

  describe "#start_stream" do
    it "returns failure when RealDebrid key is missing" do
      user.update!(realdebrid_api_key: nil)
      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("RealDebrid API key not configured")
    end

    it "returns failure when no streams available" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([A-Za-z0-9_]*/)?stream/movie/tt1375666\.json})
        .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("No streams available")
    end

    it "starts a stream successfully" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([A-Za-z0-9_]*/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 1080p", "infoHash" => "abc123def", "fileIdx" => 0, "seeders" => 100 }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:post, "https://api.real-debrid.com/rest/1.0/torrents/addMagnet")
        .to_return(
          status: 201,
          body: { "id" => "torrent123" }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, "https://api.real-debrid.com/rest/1.0/torrents/info/torrent123")
        .to_return(
          status: 200,
          body: { "id" => "torrent123", "status" => "downloaded", "files" => [], "links" => [] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:torrent_id]).to eq("torrent123")
    end
  end

  describe "#get_streaming_url" do
    it "returns streaming URL when torrent is downloaded" do
      stub_request(:get, "https://api.real-debrid.com/rest/1.0/torrents/info/torrent123")
        .to_return(
          status: 200,
          body: {
            "id" => "torrent123",
            "status" => "downloaded",
            "progress" => 100,
            "files" => [{ "id" => 0, "path" => "/movie.mkv", "bytes" => 1_500_000_000, "selected" => 1 }],
            "links" => ["https://rd.link/file123"]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:post, "https://api.real-debrid.com/rest/1.0/unrestrict/link")
        .to_return(
          status: 200,
          body: {
            "download" => "https://download.real-debrid.com/d/file123",
            "filename" => "movie.mkv",
            "filesize" => 1_500_000_000
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.get_streaming_url("torrent123")
      expect(result).to be_success
      expect(result.data[:status]).to eq("ready")
      expect(result.data[:streaming_url]).to include("download.real-debrid.com")
    end

    it "returns streaming URL when link is available even while downloading" do
      stub_request(:get, "https://api.real-debrid.com/rest/1.0/torrents/info/torrent123")
        .to_return(
          status: 200,
          body: {
            "id" => "torrent123",
            "status" => "downloading",
            "progress" => 30,
            "files" => [{ "id" => 0, "path" => "/movie.mkv", "bytes" => 1_500_000_000, "selected" => 1 }],
            "links" => ["https://rd.link/file123"]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:post, "https://api.real-debrid.com/rest/1.0/unrestrict/link")
        .to_return(
          status: 200,
          body: { "download" => "https://download.real-debrid.com/d/file123", "filename" => "movie.mkv" }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.get_streaming_url("torrent123")
      expect(result).to be_success
      expect(result.data[:status]).to eq("ready")
      expect(result.data[:streaming_url]).to include("download.real-debrid.com")
    end

    it "returns progress when no links available yet" do
      stub_request(:get, "https://api.real-debrid.com/rest/1.0/torrents/info/torrent123")
        .to_return(
          status: 200,
          body: {
            "id" => "torrent123",
            "status" => "downloading",
            "progress" => 45,
            "files" => [],
            "links" => []
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.get_streaming_url("torrent123")
      expect(result).to be_success
      expect(result.data[:status]).to eq("downloading")
      expect(result.data[:progress]).to eq(45)
    end
  end
end
