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

      it "paginates results with default page size of 25" do
        metas = 50.times.map { |i| { "id" => "tt#{i.to_s.rjust(7, '0')}", "name" => "Movie #{i}", "releaseInfo" => "2020" } }

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => metas }.to_json, headers: { 'Content-Type' => 'application/json' })

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get search_index_path(q: "movie")
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Showing 1")
        expect(response.body).to include("of 50 results")
      end

      it "respects custom per_page parameter" do
        metas = 100.times.map { |i| { "id" => "tt#{i.to_s.rjust(7, '0')}", "name" => "Movie #{i}" } }

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => metas }.to_json, headers: { 'Content-Type' => 'application/json' })

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get search_index_path(q: "movie", per_page: 50)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Showing 1")
        expect(response.body).to include("of 100 results")
      end

      it "caps per_page at 200" do
        metas = 10.times.map { |i| { "id" => "tt#{i.to_s.rjust(7, '0')}", "name" => "Movie #{i}" } }

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => metas }.to_json, headers: { 'Content-Type' => 'application/json' })

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get search_index_path(q: "movie", per_page: 999)
        expect(response).to have_http_status(:ok)
      end

      it "navigates to page 2" do
        metas = 60.times.map { |i| { "id" => "tt#{i.to_s.rjust(7, '0')}", "name" => "Movie #{i}" } }

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => metas }.to_json, headers: { 'Content-Type' => 'application/json' })

        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
          .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        get search_index_path(q: "movie", page: 2, per_page: 25)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Showing 26")
        expect(response.body).to include("of 60 results")
      end
    end
  end
end
