require "rails_helper"

RSpec.describe "WatchedItems", type: :request do
  let(:user) { create(:user) }
  let(:referer) { content_path(type: "movie", imdb_id: "tt1375666") }

  it "requires sign in" do
    patch content_watched_path(type: "movie", imdb_id: "tt1375666"), params: { watched: true }

    expect(response).to redirect_to(new_user_session_path)
  end

  context "when signed in" do
    before { sign_in user }

    it "marks a movie watched and returns to the title page" do
      expect {
        patch content_watched_path(type: "movie", imdb_id: "tt1375666"),
              params: { watched: true, title: "Inception", duration_seconds: 7_200 },
              headers: { "HTTP_REFERER" => referer }
      }.to change(user.playback_progresses, :count).by(1)

      expect(response).to redirect_to(referer)
      expect(flash[:notice]).to eq("Marked as watched.")
      entry = user.playback_progresses.movies_only.find_by(imdb_id: "tt1375666")
      expect(entry).to be_completed
      expect(entry.progress_percentage).to eq(100)
    end

    it "marks a movie unwatched" do
      create(:playback_progress, :movie, user: user, imdb_id: "tt1375666", completed: true)

      expect {
        patch content_watched_path(type: "movie", imdb_id: "tt1375666"),
              params: { watched: "false" },
              headers: { "HTTP_REFERER" => referer }
      }.to change(user.playback_progresses, :count).by(-1)

      expect(response).to redirect_to(referer)
      expect(flash[:notice]).to eq("Marked as unwatched.")
    end

    it "marks one episode watched" do
      patch content_watched_path(type: "show", imdb_id: "tt0903747"),
            params: { watched: true, season: 1, episode: 2, title: "Cat's in the Bag..." },
            headers: { "HTTP_REFERER" => content_path(type: "show", imdb_id: "tt0903747") }

      entry = user.playback_progresses.find_by(season_number: 1, episode_number: 2)
      expect(entry).to be_completed
      expect(response).to redirect_to(content_path(type: "show", imdb_id: "tt0903747"))
    end

    it "does not change another user's progress" do
      other_entry = create(:playback_progress, :movie, user: create(:user), imdb_id: "tt1375666")

      patch content_watched_path(type: "movie", imdb_id: "tt1375666"), params: { watched: true }

      expect(other_entry.reload).not_to be_completed
      expect(user.playback_progresses.find_by(imdb_id: "tt1375666")).to be_completed
    end

    it "requires an explicit watched state" do
      patch content_watched_path(type: "movie", imdb_id: "tt1375666")

      expect(response).to redirect_to(referer)
      expect(flash[:alert]).to eq("Watched state is required.")
      expect(user.playback_progresses).to be_empty
    end

    it "rejects an invalid IMDb id" do
      patch content_watched_path(type: "movie", imdb_id: "not_an_imdb_id"), params: { watched: true }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Invalid content ID.")
    end
  end

  context "with a child account" do
    let(:child) { create(:user, :age_restricted) }

    before do
      sign_in child
      allow(ParentalControls::RatingResolver).to receive(:new)
        .and_return(instance_double(ParentalControls::RatingResolver, min_age: 18))
    end

    it "refuses to mark a title above the rating limit" do
      expect {
        patch content_watched_path(type: "movie", imdb_id: "tt0994312"),
              params: { watched: true, title: "Late Night Thriller" },
              headers: { "HTTP_REFERER" => content_path(type: "movie", imdb_id: "tt0994312") }
      }.not_to change(PlaybackProgress, :count)

      expect(response).to redirect_to(content_path(type: "movie", imdb_id: "tt0994312"))
      expect(flash[:alert]).to eq("This content is not available for this account.")
    end
  end
end
