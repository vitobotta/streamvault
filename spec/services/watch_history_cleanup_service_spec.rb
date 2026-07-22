require "rails_helper"

RSpec.describe WatchHistoryCleanupService do
  let(:user) { create(:user) }

  describe ".remove" do
    it "removes every history row for the selected movie" do
      selected = create(:watch_history_entry, :movie, user: user, imdb_id: "tt1375666")
      create(:watch_history_entry, :movie, user: user, imdb_id: "tt0468569")

      result = described_class.remove(user: user, entry: selected)

      expect(result).to be_success
      expect(user.watch_history_entries.pluck(:imdb_id)).to eq([ "tt0468569" ])
    end

    it "removes every episode row for the selected show" do
      selected = create(:watch_history_entry, :episode, user: user, show_imdb_id: "tt0903747", season_number: 1, episode_number: 1)
      create(:watch_history_entry, :episode, user: user, show_imdb_id: "tt0903747", season_number: 1, episode_number: 2)
      create(:watch_history_entry, :episode, user: user, show_imdb_id: "tt0944947")

      described_class.remove(user: user, entry: selected)

      expect(user.watch_history_entries.where(show_imdb_id: "tt0903747")).to be_empty
      expect(user.watch_history_entries.where(show_imdb_id: "tt0944947")).to exist
    end
  end

  describe ".clear" do
    it "clears history and episode progress together" do
      create(:watch_history_entry, user: user)
      create(:episode_progress, user: user)

      result = described_class.clear(user: user)

      expect(result).to be_success
      expect(user.watch_history_entries).to be_empty
      expect(user.episode_progresses).to be_empty
    end
  end
end
