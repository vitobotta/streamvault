require 'rails_helper'

RSpec.describe "Library", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /library" do
    context "when not authenticated" do
      it "redirects to login" do
        get library_index_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get library_index_path
        expect(response).to have_http_status(:ok)
      end

      it "filters by type" do
        create(:library_entry, user: user, content_type: :movie)
        create(:library_entry, user: user, content_type: :show)

        get library_index_path, params: { type: "movie" }
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /library" do
    before { sign_in user }

    it "creates a library entry" do
      expect {
        post library_index_path, params: { library_entry: { content_type: "movie", imdb_id: "tt1375666", title: "Inception" } }
      }.to change(LibraryEntry, :count).by(1)

      expect(response).to redirect_to(library_index_path)
    end

    it "removes from wishlist when adding to library" do
      create(:wishlist_entry, user: user, imdb_id: "tt1375666")

      expect {
        post library_index_path, params: { library_entry: { content_type: "movie", imdb_id: "tt1375666", title: "Inception" } }
      }.to change(WishlistEntry, :count).by(-1)
    end
  end

  describe "PATCH /library/:id" do
    let(:entry) { create(:library_entry, user: user) }

    before { sign_in user }

    it "updates the entry" do
      patch library_path(entry), params: { library_entry: { watch_status: "watching" } }
      expect(response).to redirect_to(library_index_path)
      expect(entry.reload.watch_status).to eq("watching")
    end

    it "denies updating other user's entry" do
      other_entry = create(:library_entry, user: other_user)
      patch library_path(other_entry), params: { library_entry: { watch_status: "watching" } }
      expect(response).to redirect_to(root_path)
    end
  end

  describe "DELETE /library/:id" do
    let!(:entry) { create(:library_entry, user: user) }

    before { sign_in user }

    it "deletes the entry" do
      expect {
        delete library_path(entry)
      }.to change(LibraryEntry, :count).by(-1)

      expect(response).to redirect_to(library_index_path)
    end
  end
end
