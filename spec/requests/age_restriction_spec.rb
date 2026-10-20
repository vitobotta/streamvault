# frozen_string_literal: true

require "rails_helper"

# End-to-end coverage for age-restricted profiles: search and listings
# must only surface titles within the age cap, and titles above the cap
# must stay unreachable through direct item URLs and playback.
RSpec.describe "Age restrictions", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:restricted_user) { create(:user, :age_restricted, realdebrid_api_key: "test_key") }

  # RatingResolver skips OMDB entirely unless a key is configured, so without
  # this every title resolves to UNKNOWN_AGE and the whole catalogue is hidden -
  # masking what these specs are actually testing.
  around do |ex|
    previous = { "STREAM_PROVIDER" => ENV["STREAM_PROVIDER"], "OMDB_API_KEY" => ENV["OMDB_API_KEY"] }
    ENV["STREAM_PROVIDER"] = "torrentio"
    ENV["OMDB_API_KEY"] = "test_key"
    begin
      ex.run
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end

  before do
    # Rating lookups fall back to TMDB when a title has no MPAA/TV rating.
    stub_request(:get, %r{api\.themoviedb\.org/3/find/})
      .to_return(status: 200, body: { "movie_results" => [], "tv_results" => [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  # Ratings per IMDb ID ("N/A" for anything not listed).
  def stub_ratings(ratings_by_id)
    stub_request(:get, %r{www\.omdbapi\.com}).to_return do |request|
      query = URI.decode_www_form(request.uri.to_s.split("?", 2).last.to_s).to_h
      imdb_id = query["i"]
      { body: { "Response" => "True", "Rated" => ratings_by_id[imdb_id] || "N/A" }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
  end

  def stub_search(metas)
    stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
      .to_return(status: 200, body: { "metas" => metas }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
      .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe "search results" do
    let(:search_metas) do
      [
        { "id" => "tt1375666", "name" => "Family Adventure", "releaseInfo" => "2010" },
        { "id" => "tt0994312", "name" => "Late Night Thriller", "releaseInfo" => "1994" }
      ]
    end

    it "only returns titles within the age cap for a restricted profile" do
      sign_in restricted_user
      stub_search(search_metas)
      stub_ratings("tt1375666" => "PG-13", "tt0994312" => "R")

      get search_index_path(q: "test")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Family Adventure")
      expect(response.body).not_to include("Late Night Thriller")
    end

    it "explains the empty catalogue when no rating source is configured" do
      sign_in restricted_user
      stub_search(search_metas)
      stub_ratings({})
      original = ENV["OMDB_API_KEY"]
      ENV.delete("OMDB_API_KEY")

      get search_index_path(q: "test")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("no film rating source is")
      expect(response.body).to include("OMDB_API_KEY")
    ensure
      ENV["OMDB_API_KEY"] = original
    end

    it "hides titles whose rating cannot be verified" do
      sign_in restricted_user
      stub_search(search_metas)
      stub_ratings({})

      get search_index_path(q: "test")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Family Adventure")
      expect(response.body).not_to include("Late Night Thriller")
    end

    it "hides titles that only carry a pre-1968 censorship seal (regression: Dracula 1931)" do
      sign_in restricted_user
      stub_search([ { "id" => "tt0021814", "name" => "Dracula", "releaseInfo" => "1931" } ])
      stub_ratings("tt0021814" => "Passed")

      get search_index_path(q: "dracula")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Dracula")
    end

    it "keeps returning every title for regular accounts" do
      sign_in user
      stub_search(search_metas)
      stub_ratings("tt1375666" => "PG-13", "tt0994312" => "R")

      get search_index_path(q: "test")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Family Adventure")
      expect(response.body).to include("Late Night Thriller")
    end
  end

  describe "direct item URLs" do
    it "never returns the content page for a title above the age cap" do
      sign_in restricted_user
      stub_ratings("tt0994312" => "R")

      get content_path(type: "movie", imdb_id: "tt0994312")

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("This content is not available for this account.")
      expect(WebMock).not_to have_requested(:get, %r{v3-cinemeta\.strem\.io/meta/})
    end

    it "returns the content page for a title within the age cap" do
      sign_in restricted_user
      stub_ratings("tt1375666" => "PG-13")
      stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
        .to_return(status: 200, body: { "meta" => { "id" => "tt1375666", "name" => "Family Adventure", "year" => "2010" } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      get content_path(type: "movie", imdb_id: "tt1375666")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Family Adventure")
    end

    it "never returns episode streams for a show above the age cap" do
      sign_in restricted_user
      stub_ratings("tt0903747" => "TV-MA")

      get episode_streams_path(type: "show", imdb_id: "tt0903747", season: 1, episode: 1)

      expect(response).to have_http_status(:forbidden)
      expect(WebMock).not_to have_requested(:get, %r{v3-cinemeta\.strem\.io/meta/})
    end
  end

  describe "playback" do
    it "never starts a stream for a title above the age cap" do
      sign_in restricted_user
      stub_ratings("tt0994312" => "R")

      post streaming_index_path, params: { imdb_id: "tt0994312", type: "movie", title: "Late Night Thriller" }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("This content is not available for this account.")
      expect(WebMock).not_to have_requested(:get, %r{torrentio\.strem\.fun})
    end

    it "rejects a playback link issued before the profile became restricted" do
      sign_in restricted_user
      stub_ratings("tt0994312" => "R")

      source_token = ResolvedSource.issue(
        user: restricted_user,
        url: "https://download.real-debrid.com/d/file123/video.mp4",
        filename: "video.mp4"
      )
      token = PlaybackDescriptor.issue(
        user: restricted_user,
        source_token: source_token,
        filename: "video.mp4",
        content_ref: ContentRef.new(imdb_id: "tt0994312", type: "movie")
      )

      get streaming_path("play", playback: token)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("This content is not available for this account.")
    end
  end

  describe "listings" do
    it "hides collected titles above the age cap" do
      create(:collection_entry, user: restricted_user, imdb_id: "tt0994312", title: "Late Night Thriller", content_type: :movie)
      create(:collection_entry, user: restricted_user, imdb_id: "tt1375666", title: "Family Adventure", content_type: :movie)
      sign_in restricted_user
      stub_ratings("tt1375666" => "PG-13", "tt0994312" => "R")

      get library_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Family Adventure")
      expect(response.body).not_to include("Late Night Thriller")
    end
  end

  describe "home rows" do
    let(:mixed_metas) do
      [
        { "id" => "tt1375666", "name" => "Family Adventure", "releaseInfo" => "2010" },
        { "id" => "tt0994312", "name" => "Late Night Thriller", "releaseInfo" => "1994" }
      ]
    end

    before do
      # Popular + trending catalogs (movies and shows) return mixed ratings.
      %w[movie series].each do |type|
        %w[top year].each do |cat|
          stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/#{type}/#{cat}})
            .to_return(status: 200, body: { "metas" => mixed_metas }.to_json, headers: { "Content-Type" => "application/json" })
        end
      end

      allow(RecommendationService).to receive(:for).and_return(
        ServiceResult.success([
          { imdb_id: "tt1375666", title: "Family Adventure", type: "movie" },
          { imdb_id: "tt0994312", title: "Late Night Thriller", type: "movie" }
        ])
      )
      stub_ratings("tt1375666" => "PG-13", "tt0994312" => "R")
    end

    it "restricts popular, trending and recommendation rows for a restricted profile" do
      sign_in restricted_user

      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Family Adventure")
      expect(response.body).not_to include("Late Night Thriller")
    end

    it "keeps every row unrestricted on regular accounts" do
      sign_in user

      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Family Adventure")
      expect(response.body).to include("Late Night Thriller")
    end
  end

  describe "account banner" do
    it "tells restricted profiles which age their results are limited to" do
      sign_in restricted_user

      get search_index_path

      expect(response.body).to include("Child account for age 13.")
      expect(response.body).to include("Search results and playback are restricted")
    end

    it "is not shown on regular accounts" do
      sign_in user

      get search_index_path

      expect(response.body).not_to include("Child account for age")
    end
  end

  describe "settings" do
    before { sign_in user }

    it "requires a settings lock to enable the restriction" do
      patch settings_path, params: { user: { child_account: "1", max_rating_age: "8" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.child_account).to eq(false)
    end

    it "enables the restriction with a settings lock and an age cap" do
      patch settings_path, params: {
        user: {
          child_account: "1", max_rating_age: "8",
          child_lock_password: "lock-1234", child_lock_password_confirmation: "lock-1234"
        }
      }

      expect(response).to redirect_to(settings_path)
      user.reload
      expect(user.child_account).to eq(true)
      expect(user.max_rating_age).to eq(8)
    end

    context "on a restricted profile" do
      before { sign_in restricted_user }

      it "refuses to disable the restriction without the settings lock" do
        patch settings_path, params: { user: { child_account: "0", child_lock_current_password: "wrong" } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(restricted_user.reload.child_account).to eq(true)
      end

      it "disables the restriction with the settings lock" do
        patch settings_path, params: { user: { child_account: "0", child_lock_current_password: "lock-1234" } }

        expect(response).to redirect_to(settings_path)
        expect(restricted_user.reload.child_account).to eq(false)
      end

      it "refuses to change the age cap without the settings lock" do
        patch settings_path, params: { user: { max_rating_age: "18" } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(restricted_user.reload.max_rating_age).to eq(13)
      end

      it "changes the age cap with the settings lock" do
        patch settings_path, params: { user: { max_rating_age: "18", child_lock_current_password: "lock-1234" } }

        expect(response).to redirect_to(settings_path)
        expect(restricted_user.reload.max_rating_age).to eq(18)
      end
    end
  end
end
