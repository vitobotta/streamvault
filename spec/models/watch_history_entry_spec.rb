require 'rails_helper'

RSpec.describe WatchHistoryEntry, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:imdb_id) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:watched_at) }
    it { is_expected.to validate_numericality_of(:progress_seconds).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:duration_seconds).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:progress_percentage).is_greater_than_or_equal_to(0).is_less_than_or_equal_to(100) }

    it { is_expected.to define_enum_for(:content_type).with_values(movie: 0, episode: 1) }
  end

  describe "scopes" do
    let!(:user) { create(:user) }
    let!(:old_entry) { create(:watch_history_entry, user: user, watched_at: 2.hours.ago) }
    let!(:new_entry) { create(:watch_history_entry, user: user, watched_at: 1.hour.ago) }
    let!(:episode) { create(:watch_history_entry, :episode, user: user) }

    describe ".recently_watched" do
      it "orders by watched_at desc" do
        expect(described_class.recently_watched.first).to eq(episode)
      end
    end

    describe ".for_show" do
      it "returns entries for the specified show" do
        expect(described_class.for_show(episode.show_imdb_id)).to include(episode)
      end
    end

    describe ".movies_only" do
      it "returns only movie entries" do
        expect(described_class.movies_only).to include(old_entry, new_entry)
        expect(described_class.movies_only).not_to include(episode)
      end
    end

    describe ".episodes_only" do
      it "returns only episode entries" do
        expect(described_class.episodes_only).to include(episode)
        expect(described_class.episodes_only).not_to include(old_entry)
      end
    end
  end
end
