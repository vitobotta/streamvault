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

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("No streams available")
    end

    it "starts a stream and returns resolved URL" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file123/Inception.mkv" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file123/Inception.mkv")
    end

    it "skips blocked streams and tries next" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file456/Inception720.mkv" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file456/Inception720.mkv")
      expect(result.data[:filename]).to eq("Inception720.mkv")
    end

    it "returns failure when all streams are blocked" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked1/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, %r{torrentio\.strem\.fun/resolve/realdebrid/test_key/blocked1/})
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("blocked")
    end

it "skips streams with failed_infringement filenames" do
  cinemeta_stub

  stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
    .to_return(
      status: 200,
      body: {
        "streams" => [
          { "title" => "Inception 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/inf/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
          { "title" => "Inception 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
        ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

  stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/inf/null/0/Inception.mkv")
    .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/abc/failed_infringement_003.mp4" })

  stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv")
    .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/def/Inception720.mkv" })

  result = service.start_stream("tt1375666", "movie")
  expect(result).to be_success
  expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/def/Inception720.mkv")
end
  end
end
