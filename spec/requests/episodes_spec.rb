require 'rails_helper'

RSpec.describe "Episodes", type: :request do
  let(:user) { create(:user) }

  describe "GET /episodes/:show_imdb_id" do
    context "when not authenticated" do
      it "redirects to login" do
        get episodes_path(show_imdb_id: "tt0903747")
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        stub_request(:get, "https://www.omdbapi.com/")
          .with(query: hash_including(i: "tt0903747"))
          .to_return(
            status: 200,
            body: { "Response" => "True", "imdbID" => "tt0903747", "Title" => "Breaking Bad", "Type" => "series", "totalSeasons" => "5" }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        get episodes_path(show_imdb_id: "tt0903747")
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
