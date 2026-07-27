require 'rails_helper'

RSpec.describe "Content", type: :request do
  let(:user) { create(:user) }

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
