require 'rails_helper'

RSpec.describe "Library", type: :request do
  let(:user) { create(:user) }

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
