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

      it "returns forbidden" do
        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie" }
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "when authenticated with RealDebrid key" do
      before { sign_in user }

      it "starts a stream" do
        stub_request(:get, %r{torrentio\.strem\.fun})
          .to_return(
            status: 200,
            body: { "streams" => [{ "title" => "Inception 1080p", "infoHash" => "abc123", "fileIdx" => 0 }] }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:post, "https://api.real-debrid.com/rest/1.0/torrents/addMagnet")
          .to_return(
            status: 201,
            body: { "id" => "torrent123" }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:post, "https://api.real-debrid.com/rest/1.0/torrents/selectFiles/torrent123")
          .to_return(status: 204)

        post streaming_index_path, params: { imdb_id: "tt1375666", type: "movie" }
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json["torrent_id"]).to eq("torrent123")
      end
    end
  end

  describe "PATCH /streaming/:id/progress" do
    before { sign_in user }

    it "saves progress" do
      create(:library_entry, user: user, imdb_id: "tt1375666")

      patch progress_streaming_path("tt1375666"), params: {
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
