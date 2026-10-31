require 'rails_helper'

RSpec.describe "Content", type: :request do
  let(:user) { create(:user) }

  def stub_show_metadata(videos: nil)
    videos ||= [
      { "id" => "tt0903747:1:1", "season" => 1, "episode" => 1, "name" => "Pilot", "released" => "2008-01-20" },
      { "id" => "tt0903747:1:2", "season" => 1, "episode" => 2, "name" => "Cat's in the Bag...", "released" => "2008-01-27" }
    ]
    stub_request(:get, "https://v3-cinemeta.strem.io/meta/series/tt0903747.json")
      .to_return(
        status: 200,
        body: {
          "meta" => {
            "id" => "tt0903747",
            "name" => "Breaking Bad",
            "year" => "2008",
            "videos" => videos
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  around do |ex|
    ENV["STREAM_PROVIDER"] = "torrentio"
    ex.run
    ENV.delete("STREAM_PROVIDER")
  end
  describe "GET /content/:type/:imdb_id" do
    context "when not authenticated" do
      it "redirects to login" do
        get content_path(type: "movie", imdb_id: "tt1375666")
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "year" => "2010" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
          .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get content_path(type: "movie", imdb_id: "tt1375666")
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-controller="page-loader"')
        expect(response.body).not_to include('data-controller="stream-loading"')
      end

      it "shows series watched when every released episode is complete" do
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 1, completed: true)
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 2, completed: true)
        stub_show_metadata

        get content_path(type: "show", imdb_id: "tt0903747")

        expect(response.body).to include("Series watched")
        expect(response.body).to include("Season watched")
        expect(response.body).to include("Season 1, watched")
        expect(response.body).to include("data-series-progress")
        expect(Nokogiri::HTML(response.body).text.squish).to include("2 of 2 episodes watched")
        expect(response.body).not_to include("Continue S01E01")
      end

      it "offers to mark a partially watched series watched" do
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 1, completed: true)
        stub_show_metadata

        get content_path(type: "show", imdb_id: "tt0903747")

        expect(response.body).to include("Mark series watched")
        expect(response.body).to include("Mark season watched")
        expect(response.body).not_to include("Season 1, watched")
        expect(response.body).to include("Season 1, 1 of 2 episodes watched")
        expect(response.body).to include("1/2")
        expect(response.body).to include("data-series-progress")
        expect(response.body).to include("aria-valuenow=\"1\"")
        expect(response.body).to include("aria-valuemax=\"2\"")
      end

      it "marks a completed season on its tab while the series is still partial" do
        entry = create(:collection_entry, :show, user: user, imdb_id: "tt0903747")
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 1, completed: true)
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 2, completed: true)
        stub_show_metadata(videos: [
          { "id" => "tt0903747:1:1", "season" => 1, "episode" => 1, "name" => "Pilot", "released" => "2008-01-20" },
          { "id" => "tt0903747:1:2", "season" => 1, "episode" => 2, "name" => "Cat's in the Bag...", "released" => "2008-01-27" },
          { "id" => "tt0903747:2:1", "season" => 2, "episode" => 1, "name" => "Seven Thirty-Seven", "released" => "2009-03-08" },
          { "id" => "tt0903747:2:2", "season" => 2, "episode" => 2, "name" => "Grilled", "released" => Date.tomorrow.iso8601 }
        ])

        get content_path(type: "show", imdb_id: "tt0903747")

        expect(response.body).to include("Mark series watched")
        expect(response.body).to include("Season 1, watched")
        expect(response.body).not_to include("Season 2, watched")
        expect(response.body).not_to include("0/1")
        expect(response.body).to include("aria-valuenow=\"2\"")
        expect(response.body).to include("aria-valuemax=\"3\"")
        expect(Nokogiri::HTML(response.body).text.squish).to include("2 of 3 episodes watched")
        expect(entry.reload.series_total_episodes).to eq(3)
        expect(entry.series_total_episodes_synced_at).to be_present
      end

      it "shows the watched state for a completed movie" do
        create(:playback_progress, :movie, user: user, imdb_id: "tt1375666", completed: true)
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt1375666", "name" => "Inception", "year" => "2010" } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
        stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
          .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get content_path(type: "movie", imdb_id: "tt1375666")

        expect(response.body).to include("Mark this film unwatched")
      end

      it "rejects an invalid imdb_id format (SEC-09)" do
        get content_path(type: "movie", imdb_id: "not_an_imdb_id")
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("Invalid content ID.")
      end

      it "rejects an invalid type format (SEC-09)" do
        get content_path(type: "invalid", imdb_id: "tt1375666")
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("Invalid content type.")
      end
    end
  end

  describe "GET /content/:type/:imdb_id/status" do
    let(:other_user) { create(:user) }

    before { sign_in user }

    it "returns the current user's unified collection state" do
      create(:collection_entry, :wishlist, user: user, imdb_id: "tt1375666")

      get content_status_path(type: "movie", imdb_id: "tt1375666")

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body).to eq("state" => "wishlist")
    end

    it "does not expose another user's membership" do
      create(:collection_entry, user: other_user, imdb_id: "tt1375666")

      get content_status_path(type: "movie", imdb_id: "tt1375666")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("state" => "none")
    end

    it "rejects an invalid imdb_id" do
      get content_status_path(type: "movie", imdb_id: "not_an_imdb_id")
      expect(response).to redirect_to(root_path)
    end

    it "rejects an invalid imdb_id with JSON 400" do
      get content_status_path(type: "movie", imdb_id: "not_an_imdb_id"),
          headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /content/:type/:imdb_id/episode_streams" do
    before { sign_in user }

    it "rejects an invalid imdb_id (SEC-09)" do
      get episode_streams_path(type: "show", imdb_id: "not_an_imdb_id", season: 1, episode: 1)
      expect(response).to redirect_to(root_path)
    end
  end
end
