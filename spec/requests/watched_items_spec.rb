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

    context "with a series" do
      let(:catalog) { instance_double(Catalog::CinemetaClient) }
      let(:episodes) do
        [
          { season: 0, episode: 1, runtime_seconds: 600, released: "2008-01-01" },
          { season: 1, episode: 1, runtime_seconds: 2_400, released: "2008-01-20" },
          { season: 1, episode: 2, runtime_seconds: 2_400, released: "2008-01-27" },
          { season: 2, episode: 1, runtime_seconds: 2_400, released: Date.tomorrow.iso8601 }
        ]
      end

      before do
        allow(Catalog::CinemetaClient).to receive(:new).and_return(catalog)
        allow(catalog).to receive(:metadata).with("tt0903747", "show", include_ratings: false)
          .and_return(ServiceResult.success(title: "Breaking Bad", poster_url: "https://img.example/bb.jpg", episodes: episodes))
      end

      it "marks every released episode watched" do
        expect {
          patch content_watched_path(type: "show", imdb_id: "tt0903747"),
                params: { watched: true, title: "Breaking Bad" },
                headers: { "HTTP_REFERER" => content_path(type: "show", imdb_id: "tt0903747") }
        }.to change(user.playback_progresses, :count).by(2)

        expect(response).to redirect_to(content_path(type: "show", imdb_id: "tt0903747"))
        expect(flash[:notice]).to eq("Marked as watched.")
        expect(user.playback_progresses.for_show("tt0903747")).to all(be_completed)
      end

      it "removes every episode when marked unwatched" do
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 1)
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 2)

        expect {
          patch content_watched_path(type: "show", imdb_id: "tt0903747"),
                params: { watched: false },
                headers: { "HTTP_REFERER" => content_path(type: "show", imdb_id: "tt0903747") }
        }.to change(user.playback_progresses, :count).by(-2)
      end

      it "marks only the requested season watched" do
        patch content_watched_path(type: "show", imdb_id: "tt0903747", season: 1),
              params: { watched: true, title: "Breaking Bad" },
              headers: { "HTTP_REFERER" => content_path(type: "show", imdb_id: "tt0903747") }

        rows = user.playback_progresses.for_show("tt0903747")
        expect(rows.map(&:season_number).uniq).to eq([ 1 ])
        expect(rows.map { |row| row.episode_number }.sort).to eq([ 1, 2 ])
      end

      it "removes only the requested season when marked unwatched" do
        create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 1)
        season_two = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 2, episode_number: 1)

        patch content_watched_path(type: "show", imdb_id: "tt0903747", season: 1),
              params: { watched: false },
              headers: { "HTTP_REFERER" => content_path(type: "show", imdb_id: "tt0903747") }

        expect(user.playback_progresses.for_show("tt0903747")).to contain_exactly(season_two)
      end
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
