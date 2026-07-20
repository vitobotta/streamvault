require 'rails_helper'

RSpec.describe "Home", type: :request do
  let(:user) { create(:user) }

  before do
    # Stub all Cinemeta catalog endpoints used by HomeController
    %w[movie series].each do |type|
      %w[top year imdbRating].each do |cat|
        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/#{type}/#{cat}})
          .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })
      end
    end

    # TMDB not configured in tests — RecommendationService returns []
    ENV["TMDB_READ_ACCESS_TOKEN"] = ""
  end

  describe "Continue Watching removal" do
    before { sign_in user }

    it "item disappears from Continue Watching after delete" do
      # With the upsert design, one row per content.
      inception = create(:watch_history_entry, :movie, user: user, imdb_id: "tt1375666",
             title: "Inception", progress_percentage: 50, watched_at: 1.minute.ago)
      create(:watch_history_entry, :movie, user: user, imdb_id: "tt0903747",
             title: "Breaking Bad", progress_percentage: 20, watched_at: 2.minutes.ago)

      # Pre-condition: both titles appear on home.
      get root_path
      expect(response.body).to include("Inception")
      expect(response.body).to include("Breaking Bad")
      # The delete button must target the entry's id (history_id).
      expect(response.body).to include("watch_history/#{inception.id}")

      # Delete the Continue Watching item.
      delete watch_history_path(inception), headers: { "HTTP_REFERER" => root_path }

      # Post-condition: Inception is gone, Breaking Bad remains.
      get root_path
      expect(response.body).not_to include("Inception")
      expect(response.body).to include("Breaking Bad")
    end
  end

  describe "GET /" do
    context "when not authenticated" do
      it "redirects to login" do
        get root_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get root_path
        expect(response).to have_http_status(:ok)
      end

      it "does not show other users' recommendations (TST-18)" do
        other_user = create(:user)
        create(:recommendation, user: other_user, title: "OTHER_USER_REC_TITLE")
        get root_path
        expect(response.body).not_to include("OTHER_USER_REC_TITLE")
      end

      it "does not show stored recommendations after the user watches them" do
        create(:watch_history_entry, :movie, user: user, imdb_id: "tt0468569")
        create(:recommendation, user: user, imdb_id: "tt0468569", title: "ALREADY_WATCHED_REC")
        create(:recommendation, user: user, imdb_id: "tt0000123", title: "UNSEEN_REC")

        get root_path

        expect(response.body).not_to include("ALREADY_WATCHED_REC")
        expect(response.body).to include("UNSEEN_REC")
      end
    end
  end
end
