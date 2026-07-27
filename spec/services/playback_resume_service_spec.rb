require "rails_helper"

RSpec.describe PlaybackResumeService do
  let(:user) { create(:user) }
  subject(:service) { described_class.new(user) }

  describe "movies" do
    it "starts from zero when no history exists" do
      result = service.call(imdb_id: "tt1375666", type: "movie")

      expect(result).to be_success
      expect(result.data).to include(season: nil, episode: nil, resume_at: 0, duration_seconds: 0)
    end

    it "resumes an incomplete movie" do
      create(:playback_progress, :movie,
        user: user,
        imdb_id: "tt1375666",
        title: "Inception",
        progress_seconds: 3_000,
        duration_seconds: 7_200)
      result = service.call(imdb_id: "tt1375666", type: "movie")

      expect(result.data).to include(resume_at: 3_000, title: "Inception", duration_seconds: 7_200)
    end

    it "restarts a completed movie" do
      create(:playback_progress, :movie,
        user: user,
        imdb_id: "tt1375666",
        progress_seconds: 6_840,
        duration_seconds: 7_200)
      expect(service.call(imdb_id: "tt1375666", type: "movie").data[:resume_at]).to eq(0)
    end
  end

  describe "shows" do
    it "starts at the first episode when no progress exists" do
      result = service.call(imdb_id: "tt0903747", type: "show")

      expect(result.data).to include(season: 1, episode: 1, resume_at: 0, series_complete: false)
    end

    it "keeps the current episode at 97.5 percent" do
      create(:playback_progress, :episode, user: user,
        imdb_id: "tt0903747",
        season_number: 1,
        episode_number: 1,
        progress_seconds: 3_393,
        duration_seconds: 3_480)

      result = service.call(imdb_id: "tt0903747", type: "show")

      expect(result.data).to include(season: 1, episode: 1, resume_at: 3_393, series_complete: false)
    end

    it "advances after the exact episode completion threshold" do
      progress = create(:playback_progress, :episode, user: user,
        imdb_id: "tt0903747",
        season_number: 1,
        episode_number: 1,
        progress_seconds: 3_411,
        duration_seconds: 3_480)
      next_ref = ContentRef.new(imdb_id: "tt0903747", type: "show", season: 1, episode: 2)
      allow_any_instance_of(Playback::EpisodeSequence).to receive(:next_after)
        .and_return(ServiceResult.success(next_ref))

      result = service.call(imdb_id: "tt0903747", type: "show")

      expect(result.data).to include(
        season: 1,
        episode: 2,
        resume_at: 0,
        title: progress.title,
        duration_seconds: 0,
        series_complete: false
      )
    end

    it "marks a completed finale without inventing another episode" do
      progress = create(:playback_progress, :episode, user: user,
        imdb_id: "tt0903747",
        season_number: 5,
        episode_number: 16,
        progress_seconds: 3_000,
        duration_seconds: 3_000)
      allow_any_instance_of(Playback::EpisodeSequence).to receive(:next_after)
        .and_return(ServiceResult.failure("No more episodes", :series_complete))

      result = service.call(imdb_id: "tt0903747", type: "show")

      expect(result.data).to include(
        season: 5,
        episode: 16,
        resume_at: 0,
        title: progress.title,
        duration_seconds: 3_000,
        series_complete: true
      )
    end
  end
end
