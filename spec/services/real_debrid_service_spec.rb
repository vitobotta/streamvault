require 'rails_helper'

RSpec.describe RealDebridService do
  subject(:service) { described_class.new("test_api_key_123") }

  let(:base_url) { "https://api.real-debrid.com/rest/1.0" }

  describe "#verify_key" do
    it "returns user info for valid key" do
      stub_request(:get, "#{base_url}/user")
        .to_return(
          status: 200,
          body: { "id" => "12345", "username" => "testuser", "type" => "premium" }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.verify_key
      expect(result).to be_success
      expect(result.data["username"]).to eq("testuser")
    end

    it "returns failure for invalid key" do
      stub_request(:get, "#{base_url}/user")
        .to_return(
          status: 401,
          body: { "error" => "Bad token", "error_code" => 8 }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.verify_key
      expect(result).to be_failure
      expect(result.error_message).to eq("Bad token")
    end
  end

  describe "#unrestrict_link" do
    it "returns failure for blank URL" do
      result = service.unrestrict_link("")
      expect(result).to be_failure
    end

    it "returns direct download link" do
      stub_request(:post, "#{base_url}/unrestrict/link")
        .to_return(
          status: 200,
          body: {
            "download" => "https://download.real-debrid.com/d/file123",
            "filename" => "movie.mp4",
            "filesize" => 1_500_000_000,
            "mimeType" => "video/mp4"
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.unrestrict_link("https://rd.link/abc123")
      expect(result).to be_success
      expect(result.data[:download_link]).to include("download.real-debrid.com")
      expect(result.data[:filename]).to eq("movie.mp4")
    end
  end

  describe "#add_magnet" do
    it "returns failure for blank magnet" do
      result = service.add_magnet("")
      expect(result).to be_failure
    end

    it "adds magnet and returns torrent info" do
      stub_request(:post, "#{base_url}/torrents/addMagnet")
        .to_return(
          status: 201,
          body: { "id" => "torrent123", "uri" => "#{base_url}/torrents/info/torrent123" }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.add_magnet("magnet:?xt=urn:btih:abc123")
      expect(result).to be_success
      expect(result.data[:id]).to eq("torrent123")
    end
  end

  describe "#torrent_info" do
    it "returns torrent information" do
      stub_request(:get, "#{base_url}/torrents/info/torrent123")
        .to_return(
          status: 200,
          body: {
            "id" => "torrent123",
            "filename" => "movie.mkv",
            "status" => "downloaded",
            "progress" => 100,
            "files" => [
              { "id" => 0, "path" => "/movie.mkv", "bytes" => 1_500_000_000, "selected" => 1 }
            ],
            "links" => ["https://rd.link/file123"]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.torrent_info("torrent123")
      expect(result).to be_success
      expect(result.data[:status]).to eq("downloaded")
      expect(result.data[:files].length).to eq(1)
    end
  end

  describe "#select_files" do
    it "selects files for download" do
      stub_request(:post, "#{base_url}/torrents/selectFiles/torrent123")
        .to_return(status: 204)

      result = service.select_files("torrent123", [0])
      expect(result).to be_success
    end
  end

  describe "rate limit handling" do
    it "retries on 429 responses" do
      stub_request(:post, "#{base_url}/unrestrict/link")
        .to_return(
          { status: 429, body: { "error" => "Too many requests" }.to_json, headers: { 'Content-Type' => 'application/json' } },
          { status: 200, body: { "download" => "https://example.com/file", "filename" => "test.mp4" }.to_json, headers: { 'Content-Type' => 'application/json' } }
        )

      result = service.unrestrict_link("https://rd.link/abc123")
      expect(result).to be_success
      expect(result.data[:download_link]).to eq("https://example.com/file")
    end
  end
end
