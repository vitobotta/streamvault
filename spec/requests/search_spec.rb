require 'rails_helper'

RSpec.describe "Search", type: :request do
  let(:user) { create(:user) }

  describe "GET /search" do
    context "when not authenticated" do
      it "redirects to login" do
        get search_index_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success without query" do
        get search_index_path
        expect(response).to have_http_status(:ok)
      end

      it "returns results with query" do
        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
          .to_return(
            status: 200,
            body: { "metas" => [{ "id" => "tt1375666", "name" => "Inception", "releaseInfo" => "2010" }] }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get search_index_path(q: "Inception")
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
