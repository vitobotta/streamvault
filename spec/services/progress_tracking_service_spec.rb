require 'rails_helper'

RSpec.describe ProgressTrackingService do
  let(:user) { create(:user) }

  describe ".save_progress" do
    it "creates a watch history entry for a movie" do
      create(:library_entry, user: user, imdb_id: "tt1375666", title: "Inception")

      result = described_class.save_progress(user, "tt1375666", 3600, 7200, type: "movie")
      expect(result).to be_success
      expect(user.watch_history_entries.count).to eq(1)
      expect(user.watch_history_entries.first.progress_percentage).to eq(50)
    end

    it "upserts instead of creating duplicates for the same movie" do
      described_class.save_progress(user, "tt1375666", 1800, 7200, type: "movie", title: "Inception")
      described_class.save_progress(user, "tt1375666", 3600, 7200, type: "movie", title: "Inception")

      expect(user.watch_history_entries.count).to eq(1)
      expect(user.watch_history_entries.first.progress_seconds).to eq(3600)
      expect(user.watch_history_entries.first.progress_percentage).to eq(50)
    end

    it "upserts instead of creating duplicates for the same episode" do
      described_class.save_progress(user, "tt0903747", 600, 2400, type: "show", season: 1, episode: 1, title: "Breaking Bad")
      described_class.save_progress(user, "tt0903747", 1200, 2400, type: "show", season: 1, episode: 1, title: "Breaking Bad")

      expect(user.watch_history_entries.count).to eq(1)
      expect(user.watch_history_entries.first.progress_seconds).to eq(1200)
    end

    it "keeps separate entries for different episodes of the same show" do
      described_class.save_progress(user, "tt0903747", 1200, 2400, type: "show", season: 1, episode: 1, title: "Breaking Bad")
      described_class.save_progress(user, "tt0903747", 600, 2400, type: "show", season: 1, episode: 2, title: "Breaking Bad")

      expect(user.watch_history_entries.count).to eq(2)
    end

    it "creates episode progress for a show" do
      create(:library_entry, user: user, imdb_id: "tt0903747", title: "Breaking Bad", content_type: :show)

      result = described_class.save_progress(user, "tt0903747", 1200, 2400, type: "show", season: 1, episode: 1)
      expect(result).to be_success
      expect(user.episode_progresses.count).to eq(1)
      expect(user.watch_history_entries.first.content_type).to eq("episode")
    end

    it "returns failure for invalid data" do
      result = described_class.save_progress(user, "tt1375666", nil, nil, type: "movie")
      expect(result).to be_failure
    end

    it "stores the poster_url passed in explicitly" do
      result = described_class.save_progress(user, "tt1375666", 3600, 7200, type: "movie", poster_url: "https://img.example.com/p.jpg")
      expect(result).to be_success
      expect(user.watch_history_entries.first.poster_url).to eq("https://img.example.com/p.jpg")
    end

    it "falls back to wishlist poster when poster_url not passed and not in library" do
      create(:wishlist_entry, user: user, imdb_id: "tt1375666", poster_url: "https://img.example.com/wish.jpg")

      result = described_class.save_progress(user, "tt1375666", 3600, 7200, type: "movie")
      expect(result).to be_success
      expect(user.watch_history_entries.first.poster_url).to eq("https://img.example.com/wish.jpg")
    end

    it "stores nil poster when not passed and not in library or wishlist" do
      result = described_class.save_progress(user, "tt1375666", 3600, 7200, type: "movie")
      expect(result).to be_success
      expect(user.watch_history_entries.first.poster_url).to be_nil
    end

    it "creates a continue-watching entry when duration is not known yet" do
      result = described_class.save_progress(user, "tt1375666", 12, 0, type: "movie", title: "Inception")

      expect(result).to be_success
      entry = user.watch_history_entries.first
      expect(entry.duration_seconds).to eq(0)
      expect(entry.progress_percentage).to eq(1)
      expect(described_class.continue_watching(user).data.first[:imdb_id]).to eq("tt1375666")
    end

    it "clamps progress percentage when progress exceeds duration" do
      result = described_class.save_progress(user, "tt1375666", 120, 60, type: "movie", title: "Inception")

      expect(result).to be_success
      expect(user.watch_history_entries.first.progress_percentage).to eq(100)
    end
  end

  describe ".get_progress" do
    it "returns latest watch history for a movie" do
      create(:watch_history_entry, user: user, imdb_id: "tt1375666", progress_seconds: 3600)

      result = described_class.get_progress(user, "tt1375666")
      expect(result).to be_success
      expect(result.data.progress_seconds).to eq(3600)
    end

    it "returns episode progress for a show" do
      create(:episode_progress, user: user, show_imdb_id: "tt0903747", season_number: 1, episode_number: 1)

      result = described_class.get_progress(user, "tt0903747", season: 1, episode: 1)
      expect(result).to be_success
      expect(result.data).to be_a(EpisodeProgress)
    end
  end

  describe ".next_episode" do
    before do
      allow_any_instance_of(TorrentioService).to receive(:metadata) do |svc, imdb_id, _type|
        ServiceResult.success({
          episodes: [
            { season: 1, episode: 1 },
            { season: 1, episode: 2 },
            { season: 2, episode: 1 }
          ]
        })
      end
    end

    it "returns the next episode within a season" do
      result = described_class.next_episode(user, "tt1", 1, 1)
      expect(result).to be_success
      expect(result.data[:season]).to eq(1)
      expect(result.data[:episode]).to eq(2)
    end

    it "crosses the season boundary" do
      result = described_class.next_episode(user, "tt1", 1, 2)
      expect(result).to be_success
      expect(result.data[:season]).to eq(2)
      expect(result.data[:episode]).to eq(1)
    end

    it "returns failure at the series finale" do
      result = described_class.next_episode(user, "tt1", 2, 1)
      expect(result).not_to be_success
    end
  end

  describe ".continue_watching" do
    it "returns partially watched content" do
      create(:watch_history_entry, user: user, imdb_id: "tt1375666", progress_percentage: 50, watched_at: 1.hour.ago)
      create(:watch_history_entry, user: user, imdb_id: "tt0903747", progress_percentage: 95, watched_at: 2.hours.ago)

      result = described_class.continue_watching(user)
      expect(result).to be_success
      expect(result.data.length).to eq(1)
      expect(result.data.first[:imdb_id]).to eq("tt1375666")
    end
  end
end
