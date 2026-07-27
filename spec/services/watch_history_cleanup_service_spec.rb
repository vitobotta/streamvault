require "rails_helper"

RSpec.describe WatchHistoryCleanupService do
  let(:user) { create(:user) }

  describe ".remove" do
    it "removes every history row for the selected movie" do
      selected = create(:playback_progress, :movie, user: user, imdb_id: "tt1375666")
      create(:playback_progress, :movie, user: user, imdb_id: "tt0468569")

      result = described_class.remove(user: user, entry: selected)

      expect(result).to be_success
      expect(user.playback_progresses.pluck(:imdb_id)).to eq([ "tt0468569" ])
    end

    it "removes every episode row for the selected show" do
      selected = create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 1)
      create(:playback_progress, :episode, user: user, imdb_id: "tt0903747", season_number: 1, episode_number: 2)
      create(:playback_progress, :episode, user: user, imdb_id: "tt0944947")

      described_class.remove(user: user, entry: selected)

      expect(user.playback_progresses.for_show("tt0903747")).to be_empty
      expect(user.playback_progresses.for_show("tt0944947")).to exist
    end
  end

  describe ".clear" do
    it "clears history and episode progress together" do
      create(:playback_progress, user: user)
      create(:playback_progress, :episode, user: user)

      result = described_class.clear(user: user)

      expect(result).to be_success
      expect(user.playback_progresses).to be_empty
    end
  end
end
