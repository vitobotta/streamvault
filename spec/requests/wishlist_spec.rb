require 'rails_helper'

RSpec.describe "Wishlist", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /wishlist" do
    context "when not authenticated" do
      it "redirects to login" do
        get wishlist_index_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get wishlist_index_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /wishlist" do
    before { sign_in user }

    it "creates a wishlist entry" do
      expect {
        post wishlist_index_path, params: { wishlist_entry: { content_type: "movie", imdb_id: "tt1375666", title: "Inception" } }
      }.to change(WishlistEntry, :count).by(1)

      expect(response).to redirect_to(wishlist_index_path)
    end

    context "with JSON request" do
      it "returns ok JSON for successful create" do
        expect {
          post wishlist_index_path,
               params: { wishlist_entry: { content_type: "movie", imdb_id: "tt1375666", title: "Inception" } },
               headers: { "Accept" => "application/json" }
        }.to change(WishlistEntry, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/json")
        body = response.parsed_body
        expect(body["ok"]).to be true
        expect(body["kind"]).to eq("wishlist")
        expect(body["destroy_url"]).to be_present
        expect(body["notice"]).to include("Inception")
      end

      it "returns error JSON for failed create" do
        create(:wishlist_entry, user: user, imdb_id: "tt1375666")

        expect {
          post wishlist_index_path,
               params: { wishlist_entry: { content_type: "movie", imdb_id: "tt1375666", title: "Inception" } },
               headers: { "Accept" => "application/json" }
        }.not_to change(WishlistEntry, :count)

        expect(response).to have_http_status(:unprocessable_content)
        body = response.parsed_body
        expect(body["ok"]).to be false
        expect(body["error"]).to be_present
      end
    end
  end

  describe "DELETE /wishlist/:id" do
    let!(:entry) { create(:wishlist_entry, user: user) }

    before { sign_in user }

    it "deletes the entry" do
      expect {
        delete wishlist_path(entry)
      }.to change(WishlistEntry, :count).by(-1)

      expect(response).to redirect_to(wishlist_index_path)
    end

    it "returns ok JSON for destroy" do
      expect {
        delete wishlist_path(entry), headers: { "Accept" => "application/json" }
      }.to change(WishlistEntry, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["ok"]).to be true
      expect(response.parsed_body["kind"]).to eq("wishlist")
    end
  end

  describe "POST /wishlist/:id/move_to_library" do
    let!(:entry) { create(:wishlist_entry, user: user) }

    before { sign_in user }

    it "moves entry to library" do
      expect {
        post move_to_library_wishlist_path(entry)
      }.to change(LibraryEntry, :count).by(1).and change(WishlistEntry, :count).by(-1)

      expect(response).to redirect_to(library_index_path)
    end
  end
end
