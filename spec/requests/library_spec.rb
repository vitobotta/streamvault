require 'rails_helper'

RSpec.describe "Library", type: :request do
  let(:user) { create(:user) }

  def stub_show_metadata(videos)
    stub_request(:get, "https://v3-cinemeta.strem.io/meta/series/tt0903747.json")
      .to_return(
        status: 200,
        body: { "meta" => { "id" => "tt0903747", "name" => "Breaking Bad", "videos" => videos } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "GET /library" do
    it "requires authentication" do
      get library_index_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows only the current user's library entries" do
      other_user = create(:user)
      visible = create(:collection_entry, user: user, title: "VISIBLE_LIBRARY_TITLE")
      create(:collection_entry, :wishlist, user: user, title: "HIDDEN_WISHLIST_TITLE")
      create(:collection_entry, user: other_user, title: "OTHER_USER_TITLE")
      sign_in user

      get library_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(visible.title)
      expect(response.body).not_to include("HIDDEN_WISHLIST_TITLE", "OTHER_USER_TITLE")
    end

    it "filters by content type" do
      create(:collection_entry, user: user, content_type: :movie, title: "MOVIE_TITLE")
      create(:collection_entry, user: user, content_type: :show, title: "SHOW_TITLE")
      sign_in user

      get library_index_path, params: { type: "movie" }

      expect(response.body).to include("MOVIE_TITLE")
      expect(response.body).not_to include("SHOW_TITLE")
    end

    it "renders the watched toggle on movie cards" do
      entry = create(:collection_entry, user: user, content_type: :movie, title: "MOVIE_TITLE")
      create(:playback_progress, :movie, user: user, imdb_id: entry.imdb_id, completed: true)
      sign_in user

      get library_index_path

      expect(response.body).to include("Mark MOVIE_TITLE unwatched")
    end

    it "leaves series cards without a single watched toggle" do
      create(:collection_entry, :show, user: user, title: "SHOW_TITLE")
      sign_in user

      get library_index_path

      expect(response.body).not_to include("Mark SHOW_TITLE")
      expect(response.body).not_to include("data-series-card-progress")
    end

    it "shows released-episode progress on series cards" do
      entry = create(:collection_entry, :show, user: user, imdb_id: "tt0903747", title: "SHOW_TITLE")
      create(:playback_progress, :episode, user: user, imdb_id: entry.imdb_id, season_number: 1, episode_number: 1, completed: true)
      create(:playback_progress, :episode, user: user, imdb_id: entry.imdb_id, season_number: 1, episode_number: 2, completed: true)
      stub_show_metadata([
        { "season" => 0, "episode" => 1, "name" => "Special", "released" => "2008-01-01" },
        { "season" => 1, "episode" => 1, "name" => "Pilot", "released" => "2008-01-20" },
        { "season" => 1, "episode" => 2, "name" => "Cat's in the Bag...", "released" => "2008-01-27" },
        { "season" => 2, "episode" => 1, "name" => "Seven Thirty-Seven", "released" => "2009-03-08" },
        { "season" => 2, "episode" => 2, "name" => "Grilled", "released" => Date.tomorrow.iso8601 }
      ])
      sign_in user

      get library_index_path

      expect(response.body).to include("data-series-card-progress")
      expect(Nokogiri::HTML(response.body).text.squish).to include("2 of 3 episodes watched")
      expect(response.body).to include('style="width: 67%"')
      expect(WebMock).to have_requested(:get, "https://v3-cinemeta.strem.io/meta/series/tt0903747.json").once
    end

    it "still renders series cards when metadata is unavailable" do
      entry = create(:collection_entry, :show, user: user, imdb_id: "tt0903747", title: "SHOW_TITLE")
      create(:playback_progress, :episode, user: user, imdb_id: entry.imdb_id, season_number: 1, episode_number: 1, completed: true)
      stub_request(:get, "https://v3-cinemeta.strem.io/meta/series/tt0903747.json").to_return(status: 500)
      sign_in user

      get library_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("SHOW_TITLE")
      expect(response.body).not_to include("data-series-card-progress")
    end
  end

  describe "PATCH /collection" do
    before { sign_in user }

    it "creates library membership and returns its state" do
      expect {
        patch collection_path,
          params: {
            state: "library",
            collection_entry: { content_type: "movie", imdb_id: "tt1375666", title: "Inception", year: 2010 }
          },
          headers: { "Accept" => "application/json" }
      }.to change(CollectionEntry, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("state" => "library")
    end

    it "moves a wishlist entry without creating a duplicate" do
      entry = create(:collection_entry, :wishlist, user: user, imdb_id: "tt1375666")

      expect {
        patch collection_path,
          params: { state: "library", collection_entry: { imdb_id: entry.imdb_id } },
          headers: { "Accept" => "application/json" }
      }.not_to change(CollectionEntry, :count)

      expect(entry.reload).to be_library
    end

    it "removes membership" do
      entry = create(:collection_entry, user: user)

      expect {
        patch collection_path,
          params: { state: "none", collection_entry: { imdb_id: entry.imdb_id } },
          headers: { "Accept" => "application/json" }
      }.to change(CollectionEntry, :count).by(-1)
    end

    it "never mutates another user's entry" do
      other_entry = create(:collection_entry, user: create(:user), imdb_id: "tt1375666")

      patch collection_path,
        params: {
          state: "wishlist",
          collection_entry: { content_type: "movie", imdb_id: other_entry.imdb_id, title: "Own copy" }
        },
        headers: { "Accept" => "application/json" }

      expect(other_entry.reload).to be_library
      expect(user.collection_entries.find_by!(imdb_id: other_entry.imdb_id)).to be_wishlist
    end

    it "rejects unknown states" do
      patch collection_path,
        params: { state: "archived", collection_entry: { imdb_id: "tt1375666" } },
        headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
