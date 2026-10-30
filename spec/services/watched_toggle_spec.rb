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
  end

  describe "series" do
    let(:catalog) { instance_double(Catalog::CinemetaClient) }
    subject(:service) { described_class.new(user, catalog: catalog) }
    let(:episodes) do
      [
        { season: 0, episode: 1, title: "Special", runtime_seconds: 600, released: "2008-01-01" },
        { season: 1, episode: 1, title: "Pilot", runtime_seconds: 2_400, released: "2008-01-20" },
        { season: 1, episode: 2, title: "Cat's in the Bag...", runtime_seconds: 2_400, released: "2008-01-27" },
        { season: 2, episode: 1, title: "Future", runtime_seconds: 2_400, released: Date.tomorrow.iso8601 }
      ]
    end

    before do
      allow(catalog).to receive(:metadata).with("tt0903747", "show", include_ratings: false)
        .and_return(ServiceResult.success(title: "Breaking Bad", poster_url: "https://img.example/bb.jpg", episodes: episodes))
    end

    it "marks every released episode and skips specials and unreleased episodes" do
      result = service.call(imdb_id: "tt0903747", type: "show", watched: true, title: "Breaking Bad")

      expect(result).to be_success
      expect(result.data).to eq(2)
      rows = user.playback_progresses.for_show("tt0903747").order(:season_number, :episode_number)
      expect(rows.map { |row| [ row.season_number, row.episode_number ] }).to eq([ [ 1, 1 ], [ 1, 2 ] ])
      expect(rows).to all(be_completed)
      expect(rows.map(&:title)).to eq([ "Breaking Bad S01E01", "Breaking Bad S01E02" ])
      expect(rows.map(&:duration_seconds)).to eq([ 2_400, 2_400 ])
      expect(rows.map(&:poster_url).uniq).to eq([ "https://img.example/bb.jpg" ])
    end

    it "is idempotent when the series is marked watched again" do
      service.call(imdb_id: "tt0903747", type: "show", watched: true, title: "Breaking Bad")

      expect {
        service.call(imdb_id: "tt0903747", type: "show", watched: true, title: "Breaking Bad")
      }.not_to change(PlaybackProgress, :count)
    end

    it "removes every episode when the series is marked unwatched" do
      service.call(imdb_id: "tt0903747", type: "show", watched: true, title: "Breaking Bad")
      other_show = create(:playback_progress, :episode, user: user, imdb_id: "tt0944947")

      expect {
        service.call(imdb_id: "tt0903747", type: "show", watched: false)
      }.to change(user.playback_progresses, :count).by(-2)

      expect(user.playback_progresses).to contain_exactly(other_show)
    end

    it "fails closed when the episode list cannot be loaded" do
      allow(catalog).to receive(:metadata).and_return(ServiceResult.failure("Unavailable"))

      result = service.call(imdb_id: "tt0903747", type: "show", watched: true)

      expect(result).to be_failure
      expect(user.playback_progresses).to be_empty
    end

    describe "a single season" do
      let(:episodes) do
        [
          { season: 0, episode: 1, runtime_seconds: 600, released: "2008-01-01" },
          { season: 1, episode: 1, runtime_seconds: 2_400, released: "2008-01-20" },
          { season: 1, episode: 2, runtime_seconds: 2_400, released: "2008-01-27" },
          { season: 2, episode: 1, runtime_seconds: 2_400, released: "2009-03-08" },
          { season: 2, episode: 2, runtime_seconds: 2_400, released: Date.tomorrow.iso8601 }
        ]
      end

      it "marks only the released episodes in that season" do
        result = service.call(imdb_id: "tt0903747", type: "show", season: 1, watched: true, title: "Breaking Bad")

        expect(result).to be_success
        expect(result.data).to eq(2)
        rows = user.playback_progresses.for_show("tt0903747").order(:season_number, :episode_number)
        expect(rows.map { |row| [ row.season_number, row.episode_number ] }).to eq([ [ 1, 1 ], [ 1, 2 ] ])
        expect(rows).to all(be_completed)
      end

      it "removes only that season when marked unwatched" do
        season_one = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 1)
        season_two = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 2, episode_number: 1)

        service.call(imdb_id: "tt0903747", type: "show", season: 1, watched: false)

        expect(user.playback_progresses.where(id: season_one.id)).to be_empty
        expect(user.playback_progresses.find(season_two.id)).to eq(season_two)
      end
    end
  end
end
