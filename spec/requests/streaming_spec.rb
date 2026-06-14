require 'rails_helper'

RSpec.describe "Streaming", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }

  describe "POST /streaming" do
    context "when not authenticated" do
      it "redirects to login" do
        post streaming_index_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated without RealDebrid key" do
      let(:user_no_key) { create(:user, realdebrid_api_key: nil) }

      before { sign_in user_no_key }

      it "redirects to settings" do
        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie" }
        expect(response).to redirect_to(settings_path)
      end
    end

    context "when authenticated with RealDebrid key" do
      before { sign_in user }

      it "starts a stream and redirects to player page" do
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "year" => "2010" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, %r{torrentio\.strem\.fun/stream/movie/tt1375666\.json})
          .to_return(
            status: 200,
            body: { "streams" => [{ "title" => "Inception 1080p", "infoHash" => "abc123", "fileIdx" => 0, "seeders" => 100 }] }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:post, "https://api.real-debrid.com/rest/1.0/torrents/addMagnet")
          .to_return(status: 201, body: { "id" => "torrent123" }.to_json, headers: { 'Content-Type' => 'application/json' })

        stub_request(:get, "https://api.real-debrid.com/rest/1.0/torrents/info/torrent123")
          .to_return(
            status: 200,
            body: { "id" => "torrent123", "status" => "downloaded", "files" => [], "links" => [] }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie", title: "Inception" }
        expect(response).to redirect_to(streaming_path("torrent123", imdb_id: "tt1375666", type: "movie", title: "Inception"))
      end
    end
  end

  describe "GET /streaming/:id" do
    before { sign_in user }

    it "renders the player page" do
      get streaming_path("torrent123", imdb_id: "tt1375666", type: "movie", title: "Inception")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("video-player")
      expect(response.body).to include("stream-player")
    end
  end

  describe "GET /streaming/:id/url" do
    before { sign_in user }

    it "returns streaming URL when ready" do
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
          body: { "download" => "https://download.real-debrid.com/d/file123", "filename" => "movie.mkv" }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get url_streaming_path("torrent123")
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("ready")
      expect(json["streaming_url"]).to include("download.real-debrid.com")
    end

    it "returns progress when still downloading" do
      stub_request(:get, "https://api.real-debrid.com/rest/1.0/torrents/info/torrent123")
        .to_return(
          status: 200,
          body: { "id" => "torrent123", "status" => "downloading", "progress" => 45 }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get url_streaming_path("torrent123")
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("downloading")
    end
  end

  describe "PATCH /streaming/:id/progress" do
    before { sign_in user }

    it "saves progress" do
      create(:library_entry, user: user, imdb_id: "tt1375666")

      patch progress_streaming_path("tt1375666"), params: {
        imdb_id: "tt1375666",
        progress_seconds: 3600,
        duration_seconds: 7200,
        type: "movie"
      }

      expect(response).to have_http_status(:ok)
      expect(user.watch_history_entries.count).to eq(1)
    end
  end
end
