require 'rails_helper'

RSpec.describe "Streaming", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }

  around do |ex|
    ENV["STREAM_PROVIDER"] = "torrentio"
    ex.run
    ENV.delete("STREAM_PROVIDER")
  end

  def expect_playback_redirect(user:, source_url:, **attributes)
    expect(response).to have_http_status(:found)
    descriptor = redirected_playback_descriptor(response, user: user)
    expect(descriptor.to_h).to include(attributes)
    source = ResolvedSource.resolve(token: descriptor.source_token, user: user, verify_dns: false)
    expect(source.url).to eq(source_url)
    descriptor
  end

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
        expect_playback_redirect(
          user: user,
          source_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
          filename: "Inception.mp4",
          content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
          title: "Inception",
          duration: 0
        )
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

        expect_playback_redirect(
          user: user,
          source_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
          filename: "Inception.mp4",
          content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
          title: "Inception",
          duration: 8_880
        )
      end

      it "redirects oversized heavy-transcode selections to a playback-safe source" do
        selected_url = "https://torrentio.strem.fun/resolve/realdebrid/test_key/huge/null/0/Inception4K.mkv"
        fallback_url = "https://torrentio.strem.fun/resolve/realdebrid/test_key/small/null/0/Inception1080.mp4"

        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "runtime" => "148 min" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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

        post streaming_index_path, params: {
          imdb_id: "tt1375666",
          type: "movie",
          title: "Inception",
          duration: 8_880,
          resolve_url: selected_url,
          filename: "Inception4K.mkv",
          raw_size: 92_898_311_496,
          video_codec: "hevc"
        }

        expect_playback_redirect(
          user: user,
          source_url: "https://download.real-debrid.com/d/small/Inception1080.mp4",
          filename: "Inception1080.mp4",
          content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
          title: "Inception",
          duration: 8_880,
          direct_play_hint: true
        )
        expect(WebMock).not_to have_requested(:get, selected_url)
      end

      it "prefers saved progress duration over metadata runtime" do
        create(:playback_progress, user: user, imdb_id: "tt1375666", progress_seconds: 3600, duration_seconds: 7200)

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

        expect_playback_redirect(
          user: user,
          source_url: "https://download.real-debrid.com/d/file123/Inception.mp4",
          filename: "Inception.mp4",
          content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
          title: "Inception",
          resume_at: 3_600.0,
          duration: 7_200
        )
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
        expect_playback_redirect(
          user: user,
          source_url: "https://download.real-debrid.com/d/file123/Inception.mkv",
          filename: "Inception.mkv",
          content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
          title: "Inception",
          duration: 0
        )
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
        expect_playback_redirect(
          user: user,
          source_url: "https://download.real-debrid.com/d/file456/Inception720.mp4",
          filename: "Inception720.mp4",
          content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
          title: "Inception",
          duration: 0
        )
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

        expect_playback_redirect(
          user: user,
          source_url: "https://download.real-debrid.com/d/file456/Inception720.mp4",
          filename: "Inception720.mp4",
          content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
          title: "Inception",
          duration: 0
        )
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

    it "resumes an incomplete movie without episode coordinates" do
      progress = create(:playback_progress, :movie,
        user: user,
        imdb_id: "tt1375666",
        title: "Inception",
        poster_url: "https://img.example.com/inception.jpg",
        progress_seconds: 3_000,
        duration_seconds: 7_200)
      resolve_url = "https://torrentio.strem.fun/resolve/realdebrid/test_key/movie/null/0/Inception.mp4"

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              {
                "title" => "Inception ENG 1080p",
                "url" => resolve_url,
                "behaviorHints" => { "filename" => "Inception.mp4" }
              }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, resolve_url)
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/movie/Inception.mp4" })

      get resume_streaming_index_path(imdb_id: "tt1375666", type: "movie")

      expect_playback_redirect(
        user: user,
        source_url: "https://download.real-debrid.com/d/movie/Inception.mp4",
        filename: "Inception.mp4",
        content_ref: { imdb_id: "tt1375666", type: "movie", season: nil, episode: nil },
        title: progress.title,
        poster_url: progress.poster_url,
        resume_at: 3_000.0,
        duration: 7_200
      )
    end

    it "resumes the current episode at 97.5% despite rounded display progress" do
      progress = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
        season_number: 1, episode_number: 1,
        progress_seconds: 3393, duration_seconds: 3480)

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/series/tt0903747:1:1\.json})
        .to_return(
          status: 200,
          body: { "streams" => [ { "title" => "Breaking Bad ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc/null/0/bb.mp4", "behaviorHints" => { "filename" => "bb.mp4" } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc/null/0/bb.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/bb/bb.mp4" })

      get resume_streaming_index_path(imdb_id: "tt0903747", type: "show")

      # Metadata (title, duration) now comes from the DB progress row,
      # not a Cinemeta round-trip — resume is faster and no external
      # metadata call is made.
      expect_playback_redirect(
        user: user,
        source_url: "https://download.real-debrid.com/d/bb/bb.mp4",
        filename: "bb.mp4",
        content_ref: { imdb_id: "tt0903747", type: "show", season: 1, episode: 1 },
        title: progress.title,
        poster_url: nil,
        resume_at: 3_393.0,
        duration: 3_480
      )
    end

    it "advances to the next episode when the last-watched is >= 98%" do
      progress = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
        season_number: 1, episode_number: 1,
        progress_seconds: 3411, duration_seconds: 3480) # > 98%

      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/series/tt0903747:1:2\.json})
        .to_return(
          status: 200,
          body: { "streams" => [ { "title" => "Breaking Bad ENG 1080p", "url" => "https://torrentio.strem.fun/resolve/realdebrid/test_key/def/null/0/bb2.mp4", "behaviorHints" => { "filename" => "bb2.mp4" } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, "https://torrentio.strem.fun/resolve/realdebrid/test_key/def/null/0/bb2.mp4")
        .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/bb2/bb2.mp4" })

      get resume_streaming_index_path(imdb_id: "tt0903747", type: "show")

      # Title comes from the DB progress row's show_title; duration is 0
      # because no progress row exists yet for the next episode.
      expect_playback_redirect(
        user: user,
        source_url: "https://download.real-debrid.com/d/bb2/bb2.mp4",
        filename: "bb2.mp4",
        content_ref: { imdb_id: "tt0903747", type: "show", season: 1, episode: 2 },
        title: progress.title,
        poster_url: nil,
        resume_at: 0.0,
        duration: 0
      )
    end

    it "leaves the ended player in place when autoplay reaches the series finale" do
      create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
        season_number: 1, episode_number: 2,
        progress_seconds: 2880, duration_seconds: 2880)

      get resume_streaming_index_path(
        imdb_id: "tt0903747",
        type: "show",
        autoplay: "1"
      )

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "GET /streaming/:id" do
    before { sign_in user }

    it "renders the player from a signed playback descriptor without exposing the source URL" do
      playback = signed_playback_for(
        user,
        url: "https://download.real-debrid.com/d/file123/Inception.mp4",
        filename: "Inception.mp4",
        title: "Inception"
      )

      get streaming_path("play", playback: playback)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("video-player")
      expect(response.body).not_to include("https://download.real-debrid.com")
      expect(response.body).to include(%(data-video-player-source-value="))
      expect(response.body).to include(%(data-video-player-target="startupOverlay"))
      expect(response.body).to include("Starting playback")
      expect(response.body).to include(%(data-video-player-default-language-value="ENG"))
      expect(response.body).to include(%(data-video-player-direct-play-hint-value="false"))
      expect(response.body).to include(%(data-video-player-tracks-url-value="/transcode/tracks"))
      expect(response.body).to include(%(data-video-player-seek-url-value="/transcode/seek"))
      expect(response.body).to include(%(data-video-player-subtitles-url-value="/transcode/subtitles"))
      expect(response.body).to include(%(data-video-player-target="audioControls"))
      expect(response.body).to include(%(data-video-player-target="subtitleControls"))
      expect(response.body).to include(%(data-video-player-target="subtitleOverlay"))
      expect(response.body).to include(%(click-&gt;video-player#navigateBack))
      expect(response.body).to include("toggleAudioMenu")
      expect(response.body).to include("toggleSubtitleMenu")
    end

    it "renders the direct-play preload hint" do
      playback = signed_playback_for(user, direct_play_hint: true)

      get streaming_path("play", playback: playback)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(data-video-player-direct-play-hint-value="true"))
    end

    it "uses the signed source on transcode endpoints for MKV files" do
      playback = signed_playback_for(
        user,
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        filename: "Inception.mkv",
        title: "Inception"
      )

      get streaming_path("play", playback: playback)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/transcode?source=")
      expect(response.body).not_to include("streaming_url=")
    end

    it "renders the known duration for the player controller" do
      playback = signed_playback_for(user, title: "Inception", duration: 8_880)

      get streaming_path("play", playback: playback)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(data-video-player-duration-value="8880"))
      expect(response.body).to include(%(data-video-player-progress-url-value="/streaming/play/progress"))
      expect(response.body).to include(">2:28:00</span>")
      expect(response.body).not_to include("new MutationObserver")
      expect(response.body).not_to include("performKnownDurationSeek")
      expect(response.body).not_to include("progressFallbackAttached")
    end

    it "renders progress metadata when duration is unknown" do
      playback = signed_playback_for(user, title: "Inception")

      get streaming_path("play", playback: playback)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(data-video-player-progress-url-value="/streaming/play/progress"))
      expect(response.body).to include(%(data-video-player-duration-value="0"))
      expect(response.body).not_to include("progressFallbackAttached")
      expect(response.body).not_to include("duration_seconds: durationSeconds()")
    end

    it "rejects a tampered playback descriptor" do
      get streaming_path("play", playback: "tampered")

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Playback link is invalid or expired.")
    end
  end

  describe "PATCH /streaming/:id/progress" do
    before do
      sign_in user
      stub_request(:get, %r{v3-cinemeta\.strem\.io/meta/})
        .to_return(
          status: 200,
          body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "poster" => "https://img.example.com/poster.jpg" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "saves progress" do
      create(:collection_entry, user: user, imdb_id: "tt1375666")

      patch progress_streaming_path("play"), params: {
        imdb_id: "tt1375666",
        progress_seconds: 3600,
        duration_seconds: 7200,
        type: "movie"
      }

      expect(response).to have_http_status(:ok)
      expect(user.playback_progresses.count).to eq(1)
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
      entry = user.playback_progresses.first
      expect(entry.poster_url).to eq("https://img.example.com/inception.jpg")
    end

    it "falls back to wishlist poster when poster_url not sent" do
      create(:collection_entry, :wishlist, user: user, imdb_id: "tt1375666", poster_url: "https://img.example.com/wish.jpg")

      patch progress_streaming_path("play"), params: {
        imdb_id: "tt1375666",
        progress_seconds: 3600,
        duration_seconds: 7200,
        type: "movie"
      }

      expect(response).to have_http_status(:ok)
      expect(user.playback_progresses.first.poster_url).to eq("https://img.example.com/wish.jpg")
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
      entry = user.playback_progresses.first
      expect(entry.title).to eq("Inception")
      expect(entry.duration_seconds).to eq(0)
      expect(entry.progress_percentage).to eq(1)
    end
  end

  describe "POST /streaming/stall_telemetry" do
    before { sign_in user }

    it "logs the correlated playback state from the JSON request body" do
      allow(Rails.logger).to receive(:info)

      post stall_telemetry_streaming_index_path, as: :json, params: {
        event: "mse_quota",
        playback_id: "playback-123",
        path: "mse_transcode",
        position: 120.5,
        buffer_ahead: 29.5,
        recovery_count: 1,
        ready_state: 3,
        network_state: 2,
        mse_pending_bytes: 4096,
        mse_quota_errors: 1,
        buffered_ranges: [ [ 90.0, 150.0 ] ],
        video_codec: "hevc",
        video_width: 3840,
        video_height: 2160
      }

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:info).with(
        include(
          '[StallTelemetry] {"event":"mse_quota"',
          '"playback_id":"playback-123"',
          '"path":"mse_transcode"',
          '"position":120.5',
          '"buffered_ranges":[[90.0,150.0]]'
        )
      )
    end
  end
end
