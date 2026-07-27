require 'rails_helper'

RSpec.describe PlaybackProgress, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:playback_progress) }

    it { is_expected.to validate_presence_of(:imdb_id) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:watched_at) }
    it { is_expected.to validate_numericality_of(:progress_seconds).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:duration_seconds).is_greater_than_or_equal_to(0) }
    it { is_expected.to define_enum_for(:content_type).with_values(movie: 0, episode: 1) }
  end

  describe "behavior" do
    let!(:user) { create(:user) }
    let!(:old_movie) { create(:playback_progress, user: user, watched_at: 2.hours.ago) }
    let!(:new_movie) { create(:playback_progress, user: user, watched_at: 1.hour.ago) }
    let!(:episode) { create(:playback_progress, :episode, user: user, imdb_id: "tt1234567") }

    it "orders by watch time and scopes content types" do
      expect(described_class.recently_watched.first).to eq(episode)
      expect(described_class.movies_only).to contain_exactly(old_movie, new_movie)
      expect(described_class.for_show("tt1234567")).to contain_exactly(episode)
    end

    it "computes display percentage without storing duplicate state" do
      expect(build(:playback_progress, progress_seconds: 1_200, duration_seconds: 2_400).progress_percentage).to eq(50)
      expect(build(:playback_progress, progress_seconds: 120, duration_seconds: 60).progress_percentage).to eq(100)
      expect(build(:playback_progress, progress_seconds: 12, duration_seconds: 0).progress_percentage).to eq(1)
    end
  end
end
