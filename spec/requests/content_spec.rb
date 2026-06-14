require 'rails_helper'

RSpec.describe "Content", type: :request do
  let(:user) { create(:user) }

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
        stub_request(:get, "https://www.omdbapi.com/")
          .with(query: hash_including(i: "tt1375666"))
          .to_return(
            status: 200,
            body: { "Response" => "True", "imdbID" => "tt1375666", "Title" => "Inception", "Year" => "2010", "Type" => "movie" }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, %r{torrentio\.strem\.fun})
          .to_return(status: 200, body: { "streams" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get content_path(type: "movie", imdb_id: "tt1375666")
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
