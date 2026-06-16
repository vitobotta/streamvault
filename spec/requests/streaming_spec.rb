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

      it "starts a stream and redirects to player page with resolved URL" do
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

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

        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie", title: "Inception" }
        expect(response).to redirect_to(streaming_path("play",
          streaming_url: "https://download.real-debrid.com/d/file123/Inception.mkv",
          filename: "Inception.mkv",
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception"
        ))
      end

      it "skips blocked streams and tries next" do
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

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

        # First stream: copyright blocked
        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv")
          .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

        # Second stream: works
        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mkv")
          .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file456/Inception720.mkv" })

        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie", title: "Inception" }
        expect(response).to redirect_to(streaming_path("play",
          streaming_url: "https://download.real-debrid.com/d/file456/Inception720.mkv",
          filename: "Inception720.mkv",
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception"
        ))
      end
    end
  end

  describe "GET /streaming/:id" do
    before { sign_in user }

    it "renders the player page with video source" do
      get streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        filename: "Inception.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception"
      )
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("video-player")
      expect(response.body).to include("download.real-debrid.com")
    end
  end

  describe "PATCH /streaming/:id/progress" do
    before { sign_in user }

    it "saves progress" do
      create(:library_entry, user: user, imdb_id: "tt1375666")

      patch progress_streaming_path("play"), params: {
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
