require 'rails_helper'

RSpec.describe ContentStreamingService do
  let(:user) { create(:user, realdebrid_api_key: "test_key_123") }
  subject(:service) { described_class.new(user) }

  around do |ex|
    ENV["STREAM_PROVIDER"] = "torrentio"
    ex.run
    ENV.delete("STREAM_PROVIDER")
  end

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
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } }
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
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
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
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked1/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } }
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
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/inf/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
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

    it "skips torrentio failed_unexpected placeholder redirects" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/fail/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv", "behaviorHints" => { "filename" => "Inception720.mkv" } }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/fail/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/failed_unexpected_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/def/Inception720.mkv" })

      result = service.start_stream("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/def/Inception720.mkv")
    end

    it "chooses the default language before another preferred language" do
      user.update!(preferred_languages: %w[ENG FRENCH], default_language: "FRENCH")
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 2160p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/eng/null/0/InceptionENG.mkv", "behaviorHints" => { "filename" => "InceptionENG.mkv" } },
              { "title" => "Inception FRENCH 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/french/null/0/InceptionFrench.mkv", "behaviorHints" => { "filename" => "InceptionFrench.mkv" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/french/null/0/InceptionFrench.mkv")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/french/InceptionFrench.mkv" })

      result = service.start_stream("tt1375666", "movie")

      expect(result).to be_success
      expect(result.data[:filename]).to eq("InceptionFrench.mkv")
      expect(WebMock).not_to have_requested(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/eng/null/0/InceptionENG.mkv")
    end

    it "does not use streams outside the preferred languages" do
      user.update!(preferred_languages: %w[FRENCH], default_language: "FRENCH")
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception GERMAN 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/german/null/0/InceptionGerman.mkv", "behaviorHints" => { "filename" => "InceptionGerman.mkv" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.start_stream("tt1375666", "movie")

      expect(result).to be_failure
      expect(WebMock).not_to have_requested(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/german/null/0/InceptionGerman.mkv")
    end
  end

  describe "#resolve_single" do
    it "uses a playback-safe alternative for an oversized heavy-transcode source" do
      selected_url = "https://torrentio.strem.fun/resolve/realdebrid/test_key/huge/null/0/Inception4K.mkv"
      fallback_url = "https://torrentio.strem.fun/resolve/realdebrid/test_key/small/null/0/Inception1080.mp4"

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 2160p HEVC 💾 92.9 GB", "url" => selected_url, "behaviorHints" => { "filename" => "Inception4K.mkv" } },
              { "title" => "Inception 1080p H264 AAC 💾 12.0 GB", "url" => fallback_url, "behaviorHints" => { "filename" => "Inception1080.mp4" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, fallback_url)
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/small/Inception1080.mp4" })

      result = service.resolve_single(
        selected_url,
        filename: "Inception4K.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        duration: 8_888,
        raw_size: 92_898_311_496,
        video_codec: "hevc"
      )

      expect(result).to be_success
      expect(result.data[:filename]).to eq("Inception1080.mp4")
      expect(WebMock).not_to have_requested(:get, selected_url)
    end

    it "keeps the selected source when no playback-safe alternative exists" do
      selected_url = "https://torrentio.strem.fun/resolve/realdebrid/test_key/huge/null/0/Inception4K.mkv"

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 2160p HEVC 💾 92.9 GB", "url" => selected_url, "behaviorHints" => { "filename" => "Inception4K.mkv" } },
              { "title" => "Inception 2160p HEVC 💾 60.0 GB", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/other/null/0/InceptionOther4K.mkv", "behaviorHints" => { "filename" => "InceptionOther4K.mkv" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, selected_url)
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/huge/Inception4K.mkv" })

      result = service.resolve_single(
        selected_url,
        filename: "Inception4K.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        duration: 8_888,
        raw_size: 92_898_311_496,
        video_codec: "hevc"
      )

      expect(result).to be_success
      expect(result.data[:filename]).to eq("Inception4K.mkv")
      expect(WebMock).to have_requested(:get, selected_url).once
    end

    it "does not fetch alternatives for a sustainable selected source" do
      selected_url = "https://torrentio.strem.fun/resolve/realdebrid/test_key/small/null/0/Inception1080.mkv"
      stub_request(:get, selected_url)
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/small/Inception1080.mkv" })

      result = service.resolve_single(
        selected_url,
        filename: "Inception1080.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        duration: 8_888,
        raw_size: 10.gigabytes,
        video_codec: "hevc"
      )

      expect(result).to be_success
      expect(result.data[:filename]).to eq("Inception1080.mkv")
      expect(WebMock).not_to have_requested(:get, %r{/stream/movie/tt1375666\.json})
    end

    it "resolves the selected stream when it is available" do
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file123/Inception.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file123/Inception.mp4")
      expect(result.data[:filename]).to eq("Inception.mp4")
    end

    it "falls back to another candidate when the selected stream is blocked" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
              { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4", "behaviorHints" => { "filename" => "Inception720.mp4" } }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv")
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file456/Inception720.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv",
        filename: "Inception.mkv",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file456/Inception720.mp4")
      expect(result.data[:filename]).to eq("Inception720.mp4")
    end

    it "continues fallback resolution beyond the first small batch of candidates" do
      cinemeta_stub

      streams = (1..15).map do |index|
        { "title" => "Inception ENG blocked #{index}", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked#{index}/null/0/Inception#{index}.mkv", "behaviorHints" => { "filename" => "Inception#{index}.mkv" } }
      end
      streams << { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok16/null/0/Inception720.mp4", "behaviorHints" => { "filename" => "Inception720.mp4" } }

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: { "streams" => streams }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, %r{torrentio\.strem\.fun/resolve/realdebrid/test_key/blocked\d+/})
        .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok16/null/0/Inception720.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file789/Inception720.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked1/null/0/Inception1.mkv",
        filename: "Inception1.mkv",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file789/Inception720.mp4")
      expect(result.data[:filename]).to eq("Inception720.mp4")
    end

    it "retries a transient resolve timeout before failing the selected stream" do
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/flaky/null/0/Inception.mp4")
        .to_timeout
        .then
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file999/Inception.mp4" })

      result = service.resolve_single(
        "https://torrentio.strem.fun/resolve/realdebrid/test_key/flaky/null/0/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_success
      expect(result.data[:streaming_url]).to eq("https://download.real-debrid.com/d/file999/Inception.mp4")
    end

    it "does not fetch arbitrary resolve URLs" do
      cinemeta_stub

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      result = service.resolve_single(
        "https://example.com/internal",
        filename: "internal.mp4",
        imdb_id: "tt1375666",
        type: "movie"
      )

      expect(result).to be_failure
      expect(WebMock).not_to have_requested(:get, "https://example.com/internal")
    end
  end

  describe "candidate resolution" do
    it "returns the first completed winner without waiting for an earlier slow candidate" do
      slow = { resolve_url: "https://torrentio.strem.fun/slow" }
      fast = { resolve_url: "https://torrentio.strem.fun/fast" }
      winner = { streaming_url: "https://download.real-debrid.com/d/fast/movie.mp4", stream: fast }
      allow(service).to receive(:resolve_stream) do |stream|
        if stream == slow
          sleep 0.3
          nil
        else
          sleep 0.01
          winner
        end
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = service.send(:resolve_first_valid_batch, [ slow, fast ])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(result).to eq(winner)
      expect(elapsed).to be < 0.15
    end
  end
end
