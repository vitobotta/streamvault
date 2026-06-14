require 'rails_helper'

RSpec.describe EpisodeProgress, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:episode_progress) }

    it { is_expected.to validate_presence_of(:show_imdb_id) }
    it { is_expected.to validate_presence_of(:show_title) }
    it { is_expected.to validate_presence_of(:season_number) }
    it { is_expected.to validate_presence_of(:episode_number) }
    it { is_expected.to validate_presence_of(:last_watched_at) }
    it { is_expected.to validate_numericality_of(:season_number).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:episode_number).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:progress_seconds).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:duration_seconds).is_greater_than(0) }
    it { is_expected.to validate_uniqueness_of(:show_imdb_id).scoped_to(:user_id, :season_number, :episode_number).with_message("progress for this episode already exists") }
  end

  describe "scopes" do
    let!(:user) { create(:user) }
    let!(:ep1) { create(:episode_progress, user: user, show_imdb_id: "tt1234567", season_number: 1, episode_number: 1) }
    let!(:ep2) { create(:episode_progress, user: user, show_imdb_id: "tt1234567", season_number: 1, episode_number: 2) }
    let!(:ep3) { create(:episode_progress, user: user, show_imdb_id: "tt9999999", season_number: 1, episode_number: 1) }

    describe ".for_show" do
      it "returns episodes for the specified show" do
        expect(described_class.for_show("tt1234567")).to contain_exactly(ep1, ep2)
      end
    end

    describe ".recently_watched" do
      it "orders by last_watched_at desc" do
        expect(described_class.recently_watched.first).to eq(ep3)
      end
    end

    describe ".by_season" do
      it "returns episodes for the specified season" do
        expect(described_class.by_season(1)).to contain_exactly(ep1, ep2, ep3)
      end
    end
  end

  describe "#progress_percentage" do
    it "calculates percentage correctly" do
      progress = build(:episode_progress, progress_seconds: 1200, duration_seconds: 2400)
      expect(progress.progress_percentage).to eq(50)
    end

    it "returns 0 when duration is zero" do
      progress = build(:episode_progress, progress_seconds: 0, duration_seconds: 0)
      expect(progress.progress_percentage).to eq(0)
    end
  end

  describe "#finished?" do
    it "returns true when progress >= 90%" do
      progress = build(:episode_progress, progress_seconds: 2200, duration_seconds: 2400)
      expect(progress.finished?).to be true
    end

    it "returns false when progress < 90%" do
      progress = build(:episode_progress, progress_seconds: 1000, duration_seconds: 2400)
      expect(progress.finished?).to be false
    end
  end
end
