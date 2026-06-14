require 'rails_helper'

RSpec.describe LibraryEntry, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:library_entry) }

    it { is_expected.to validate_presence_of(:imdb_id) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_uniqueness_of(:imdb_id).scoped_to(:user_id).with_message("already in your library") }
    it { is_expected.to validate_numericality_of(:current_season).is_greater_than(0).allow_nil }
    it { is_expected.to validate_numericality_of(:current_episode).is_greater_than(0).allow_nil }
    it { is_expected.to validate_numericality_of(:year).is_greater_than(1800).is_less_than(2100).allow_nil }

    it { is_expected.to define_enum_for(:content_type).with_values(movie: 0, show: 1) }
    it { is_expected.to define_enum_for(:watch_status).with_values(not_started: 0, watching: 1, finished: 2) }
  end

  describe "scopes" do
    let!(:user) { create(:user) }
    let!(:movie) { create(:library_entry, user: user, content_type: :movie) }
    let!(:show) { create(:library_entry, user: user, content_type: :show) }
    let!(:watching) { create(:library_entry, user: user, watch_status: :watching) }

    describe ".by_type" do
      it "returns entries of the specified type" do
        expect(described_class.by_type(:movie)).to include(movie)
        expect(described_class.by_type(:movie)).not_to include(show)
      end
    end

    describe ".by_status" do
      it "returns entries with the specified status" do
        expect(described_class.by_status(:watching)).to include(watching)
      end
    end

    describe ".recently_added" do
      it "orders by created_at desc" do
        expect(described_class.recently_added.first).to eq(watching)
      end
    end

    describe ".movies" do
      it "returns only movies" do
        expect(described_class.movies).to include(movie)
        expect(described_class.movies).not_to include(show)
      end
    end

    describe ".shows" do
      it "returns only shows" do
        expect(described_class.shows).to include(show)
        expect(described_class.shows).not_to include(movie)
      end
    end
  end
end
