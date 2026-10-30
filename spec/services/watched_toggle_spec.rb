require "rails_helper"

RSpec.describe Playback::WatchedToggle do
  let(:user) { create(:user) }
  subject(:service) { described_class.new(user) }

  describe "movies" do
    it "creates a completed entry with the supplied runtime" do
      result = service.call(
        imdb_id: "tt1375666",
        type: "movie",
        watched: true,
        title: "Inception",
        poster_url: "https://img.example/inception.jpg",
        duration_seconds: 7_200
      )

      expect(result).to be_success
      entry = user.playback_progresses.movies_only.find_by(imdb_id: "tt1375666")
      expect(entry).to be_completed
      expect(entry.title).to eq("Inception")
      expect(entry.progress_seconds).to eq(7_200)
      expect(entry.duration_seconds).to eq(7_200)
      expect(entry.progress_percentage).to eq(100)
    end

    it "updates a partial entry instead of creating a second row" do
      entry = create(:playback_progress, :movie, user: user, imdb_id: "tt1375666",
        progress_seconds: 1_800, duration_seconds: 7_200)

      expect {
        service.call(imdb_id: "tt1375666", type: "movie", watched: true,
                     title: entry.title, duration_seconds: 7_200)
      }.not_to change(PlaybackProgress, :count)

      expect(entry.reload).to be_completed
      expect(entry.progress_seconds).to eq(7_200)
    end

    it "completes a title when the catalogue has no runtime" do
      result = service.call(imdb_id: "tt1375666", type: "movie", watched: true, title: "Inception")

      expect(result.data).to be_completed
      expect(result.data.duration_seconds).to eq(0)
      expect(result.data.progress_percentage).to eq(100)
    end

    it "removes the progress row when marked unwatched" do
      create(:playback_progress, :movie, user: user, imdb_id: "tt1375666", completed: true)

      expect {
        service.call(imdb_id: "tt1375666", type: "movie", watched: false)
      }.to change(user.playback_progresses, :count).by(-1)
    end

    it "never touches another user's progress" do
      other_user = create(:user)
      other_entry = create(:playback_progress, :movie, user: other_user, imdb_id: "tt1375666")

      service.call(imdb_id: "tt1375666", type: "movie", watched: false)

      expect(other_entry.reload).to be_present
    end
  end

  describe "episodes" do
    it "completes only the requested episode" do
      sibling = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
        season_number: 1, episode_number: 1, progress_seconds: 600, duration_seconds: 2_400)

      result = service.call(
        imdb_id: "tt0903747",
        type: "show",
        season: 1,
        episode: 2,
        watched: true,
        title: "Cat's in the Bag...",
        duration_seconds: 2_400
      )

      expect(result).to be_success
      expect(user.playback_progresses.for_show("tt0903747").count).to eq(2)
      watched = user.playback_progresses.find_by(season_number: 1, episode_number: 2)
      expect(watched).to be_completed
      expect(sibling.reload).not_to be_completed
      expect(sibling.progress_seconds).to eq(600)
    end

    it "removes only the requested episode when marked unwatched" do
      first = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
        season_number: 1, episode_number: 1)
      second = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
        season_number: 1, episode_number: 2)

      service.call(imdb_id: "tt0903747", type: "show", season: 1, episode: 1, watched: false)

      expect(user.playback_progresses.for_show("tt0903747").pluck(:id)).to eq([ second.id ])
      expect(PlaybackProgress.where(id: first.id)).to be_empty
    end

    it "rejects a show without an episode" do
      expect(service.call(imdb_id: "tt0903747", type: "show", watched: true)).to be_failure
    end
  end
end
