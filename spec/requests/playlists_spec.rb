require "rails_helper"

RSpec.describe "Playlists", type: :request do
  let(:user) { create(:user) }

  describe "authentication" do
    it "requires sign in" do
      get playlists_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /playlists" do
    before { sign_in user }

    it "shows only the current user's playlists" do
      mine = create(:playlist, user: user, name: "MY PLAYLIST")
      create(:playlist, user: create(:user), name: "SOMEONE ELSE")

      get playlists_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mine.name)
      expect(response.body).not_to include("SOMEONE ELSE")
    end
  end

  describe "POST /playlists" do
    before { sign_in user }

    it "creates a playlist" do
      expect {
        post playlists_path, params: { playlist: { name: "Weekend", description: "Slow burners" } }
      }.to change(user.playlists, :count).by(1)

      expect(response).to redirect_to(playlist_path(user.playlists.last))
      expect(user.playlists.last.name).to eq("Weekend")
    end

    it "creates a playlist and its first item together" do
      expect {
        post playlists_path, params: {
          playlist: { name: "Sci-fi" },
          playlist_item: { imdb_id: "tt1375666", content_type: "movie", title: "Inception", year: 2010 }
        }
      }.to change(Playlist, :count).by(1)
      expect(PlaylistItem.count).to eq(1)

      expect(user.playlists.last.playlist_items.first.title).to eq("Inception")
    end

    it "renders the index when the name is blank" do
      post playlists_path, params: { playlist: { name: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "playlist membership" do
    before { sign_in user }

    let(:playlist) { create(:playlist, user: user) }
    let(:item_attributes) do
      { imdb_id: "tt1375666", content_type: "movie", title: "Inception", poster_url: "https://example.com/i.jpg", year: 2010 }
    end

    it "adds an item" do
      expect {
        post playlist_playlist_items_path(playlist), params: { playlist_item: item_attributes }
      }.to change(playlist.playlist_items, :count).by(1)

      expect(playlist.playlist_items.last.position).to eq(0)
    end

    it "does not add the same title twice" do
      create(:playlist_item, playlist: playlist, imdb_id: "tt1375666", content_type: :movie)

      expect {
        post playlist_playlist_items_path(playlist), params: { playlist_item: item_attributes }
      }.not_to change(PlaylistItem, :count)
    end

    it "removes an item and closes the gap" do
      first = create(:playlist_item, playlist: playlist)
      second = create(:playlist_item, playlist: playlist)

      delete playlist_playlist_item_path(playlist, first)

      expect(playlist.playlist_items.reload.to_a).to eq([ second ])
      expect(second.reload.position).to eq(0)
    end

    it "moves an item earlier" do
      first = create(:playlist_item, playlist: playlist, title: "First")
      second = create(:playlist_item, playlist: playlist, title: "Second")

      patch move_playlist_playlist_item_path(playlist, second), params: { direction: "up" }

      expect(playlist.playlist_items.reload.map(&:title)).to eq([ "Second", "First" ])
    end

    it "never adds to another user's playlist" do
      other_playlist = create(:playlist, user: create(:user))

      post playlist_playlist_items_path(other_playlist), params: { playlist_item: item_attributes }

      expect(response).to redirect_to(root_path)
      expect(other_playlist.playlist_items).to be_empty
    end
  end

  describe "child accounts" do
    let(:child) { create(:user, :age_restricted) }

    before do
      sign_in child
      allow(ParentalControls::RatingResolver).to receive(:new)
        .and_return(instance_double(ParentalControls::RatingResolver, min_age: 18))
    end

    it "refuses to add a title above the age cap" do
      playlist = create(:playlist, user: child)

      expect {
        post playlist_playlist_items_path(playlist), params: {
          playlist_item: { imdb_id: "tt0994312", content_type: "movie", title: "Late Night Thriller" }
        }
      }.not_to change(PlaylistItem, :count)

      expect(response).to redirect_to(playlist_path(playlist))
      expect(flash[:alert]).to include("not available")
    end
  end
end
