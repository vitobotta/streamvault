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
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
          .to_return(
            status: 200,
            body: {
              "streams" => [
                { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4", "behaviorHints" => { "filename" => "Inception.mp4" } }
              ]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4")
          .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file123/Inception.mp4" })

        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie", title: "Inception" }
        expect(response).to redirect_to(streaming_path("play",
          streaming_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
          filename: "Inception.mp4",
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          duration: 0
        ))
      end

      it "passes metadata runtime to the player duration" do
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "runtime" => "148 min" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4")
          .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file123/Inception.mp4" })

        post streaming_index_path, params: {
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          resolve_url: "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4",
          filename: "Inception.mp4"
        }

        expect(response).to redirect_to(streaming_path("play",
          streaming_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
          filename: "Inception.mp4",
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          duration: 8880
        ))
      end

      it "prefers saved progress duration over metadata runtime" do
        create(:watch_history_entry, user: user, imdb_id: "tt1375666", progress_seconds: 3600, duration_seconds: 7200)

        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "runtime" => "148 min" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4")
          .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file123/Inception.mp4" })

        post streaming_index_path, params: {
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          resolve_url: "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mp4",
          filename: "Inception.mp4"
        }

        expect(response).to redirect_to(streaming_path("play",
          streaming_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
          filename: "Inception.mp4",
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          resume_at: 3600,
          duration: 7200
        ))
      end

      it "marks MKV streams for transcoding" do
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
                { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc123/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } }
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
          title: "Inception",
          duration: 0
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
                { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
                { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4", "behaviorHints" => { "filename" => "Inception720.mp4" } }
              ]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv")
          .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4")
          .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file456/Inception720.mp4" })

        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie", title: "Inception" }
        expect(response).to redirect_to(streaming_path("play",
          streaming_url: "https://download.real-debrid.com/d/file456/Inception720.mp4",
          filename: "Inception720.mp4",
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          duration: 0
        ))
      end

      it "falls back when the selected stream is blocked" do
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
                { "title" => "Inception ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv", "behaviorHints" => { "filename" => "Inception.mkv" } },
                { "title" => "Inception ENG 720p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4", "behaviorHints" => { "filename" => "Inception720.mp4" } }
              ]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv")
          .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/downloading_v2.mp4" })

        stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/ok/null/0/Inception720.mp4")
          .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file456/Inception720.mp4" })

        post streaming_index_path, params: {
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          resolve_url: "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/Inception.mkv",
          filename: "Inception.mkv"
        }

        expect(response).to redirect_to(streaming_path("play",
          streaming_url: "https://download.real-debrid.com/d/file456/Inception720.mp4",
          filename: "Inception720.mp4",
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          duration: 0
        ))
      end
    end
  end

  describe "GET /streaming/resume" do
    before { sign_in user }

    # Cinemeta show metadata with S1E1/S1E2, used by resume_target + fetch_show_title
    let!(:cinemeta_stub) do
      stub_request(:get, "https://v3-cinemeta.strem.io/meta/series/tt0903747.json")
        .to_return(
          status: 200,
          body: {
            "meta" => {
              "id" => "tt0903747",
              "name" => "Breaking Bad",
              "videos" => [
                { "season" => 1, "episode" => 1, "name" => "Pilot", "runtime" => "58 min" },
                { "season" => 1, "episode" => 2, "name" => "Cat's in the Bag...", "runtime" => "48 min" }
              ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    before { cinemeta_stub }

    it "resumes a partially-watched episode at the saved position" do
      create(:episode_progress, user: user, show_imdb_id: "tt0903747",
             season_number: 1, episode_number: 1,
             progress_seconds: 600, duration_seconds: 3480)

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/series/tt0903747:1:1\.json})
        .to_return(
          status: 200,
          body: { "streams" => [ { "title" => "Breaking Bad 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc/null/0/bb.mp4", "behaviorHints" => { "filename" => "bb.mp4" } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc/null/0/bb.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/bb/bb.mp4" })

      get resume_streaming_index_path(show_imdb_id: "tt0903747", type: "show")

      expect(response).to redirect_to(streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/bb/bb.mp4",
        filename: "bb.mp4",
        imdb_id: "tt0903747",
        type: "show",
        season: 1,
        episode: 1,
        title: "Breaking Bad",
        poster_url: nil,
        resume_at: 600,
        duration: 0
      ))
    end

    it "advances to the next episode when the last-watched is >= 95%" do
      create(:episode_progress, user: user, show_imdb_id: "tt0903747",
             season_number: 1, episode_number: 1,
             progress_seconds: 3400, duration_seconds: 3480) # ~98%

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/series/tt0903747:1:2\.json})
        .to_return(
          status: 200,
          body: { "streams" => [ { "title" => "Breaking Bad 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/def/null/0/bb2.mp4", "behaviorHints" => { "filename" => "bb2.mp4" } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/def/null/0/bb2.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/bb2/bb2.mp4" })

      get resume_streaming_index_path(show_imdb_id: "tt0903747", type: "show")

      expect(response).to redirect_to(streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/bb2/bb2.mp4",
        filename: "bb2.mp4",
        imdb_id: "tt0903747",
        type: "show",
        season: 1,
        episode: 2,
        title: "Breaking Bad",
        poster_url: nil,
        resume_at: 0,
        duration: 0
      ))
    end
  end

  describe "GET /streaming/:id" do
    before { sign_in user }

    it "renders the player page with video source" do
      get streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception",
        needs_transcode: true
      )
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("video-player")
      expect(response.body).to include("download.real-debrid.com")
      expect(response.body).to include(%(data-video-player-target="startupOverlay"))
      expect(response.body).to include("Starting playback")
      expect(response.body).to include(%(data-video-player-default-language-value="ENG"))
      expect(response.body).to include(%(data-video-player-tracks-url-value="/transcode/tracks"))
      expect(response.body).to include(%(data-video-player-subtitles-url-value="/transcode/subtitles"))
      expect(response.body).to include(%(data-video-player-target="audioControls"))
      expect(response.body).to include(%(data-video-player-target="subtitleControls"))
      expect(response.body).to include(%(data-video-player-target="subtitleOverlay"))
      expect(response.body).to include(%(click-&gt;video-player#navigateBack))
      expect(response.body).to include("toggleAudioMenu")
      expect(response.body).to include("toggleSubtitleMenu")
    end

    it "uses transcode proxy for MKV files" do
      get streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        filename: "Inception.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception",
        needs_transcode: true
      )
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("transcode")
    end

    it "passes a selected subtitle stream to the transcode proxy" do
      get streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        filename: "Inception.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception",
        subtitle_stream: "4"
      )

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("subtitle_stream=4")
    end

    it "renders the known duration for the player controller" do
      get streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception",
        duration: 8880
      )

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(data-video-player-duration-value="8880"))
      expect(response.body).to include(%(data-video-player-progress-url-value="/streaming/play/progress"))
      expect(response.body).to include(">2:28:00</span>")
      expect(response.body).not_to include("new MutationObserver")
      expect(response.body).not_to include("performKnownDurationSeek")
      expect(response.body).not_to include("progressFallbackAttached")
    end

    it "backfills duration for old player URLs that still have duration zero" do
      stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
        .to_return(
          status: 200,
          body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "runtime" => "148 min" } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception",
        duration: 0
      )

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(data-video-player-duration-value="8880"))
      expect(response.body).to include(">2:28:00</span>")
    end

    it "renders progress metadata when duration is unknown" do
      get streaming_path("play",
        streaming_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
        filename: "Inception.mp4",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception"
      )

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(data-video-player-progress-url-value="/streaming/play/progress"))
      expect(response.body).to include(%(data-video-player-duration-value="0"))
      expect(response.body).not_to include("progressFallbackAttached")
      expect(response.body).not_to include("duration_seconds: durationSeconds()")
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

    it "persists poster_url passed from the player" do
      patch progress_streaming_path("play"), params: {
        imdb_id: "tt1375666",
        progress_seconds: 3600,
        duration_seconds: 7200,
        type: "movie",
        title: "Inception",
        poster_url: "https://img.example.com/inception.jpg"
      }

      expect(response).to have_http_status(:ok)
      entry = user.watch_history_entries.first
      expect(entry.poster_url).to eq("https://img.example.com/inception.jpg")
    end

    it "falls back to wishlist poster when poster_url not sent" do
      create(:wishlist_entry, user: user, imdb_id: "tt1375666", poster_url: "https://img.example.com/wish.jpg")

      patch progress_streaming_path("play"), params: {
        imdb_id: "tt1375666",
        progress_seconds: 3600,
        duration_seconds: 7200,
        type: "movie"
      }

      expect(response).to have_http_status(:ok)
      expect(user.watch_history_entries.first.poster_url).to eq("https://img.example.com/wish.jpg")
    end

    it "saves first progress tick before duration is known" do
      patch progress_streaming_path("play"), params: {
        imdb_id: "tt1375666",
        progress_seconds: 12,
        duration_seconds: 0,
        type: "movie",
        title: "Inception"
      }

      expect(response).to have_http_status(:ok)
      entry = user.watch_history_entries.first
      expect(entry.title).to eq("Inception")
      expect(entry.duration_seconds).to eq(0)
      expect(entry.progress_percentage).to eq(1)
    end
  end
end
