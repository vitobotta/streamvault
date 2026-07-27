require 'rails_helper'

RSpec.describe CollectionEntry, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:collection_entry) }

    it { is_expected.to validate_presence_of(:imdb_id) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_uniqueness_of(:imdb_id).scoped_to(:user_id).with_message("already in your collection") }
    it { is_expected.to validate_numericality_of(:year).is_greater_than(1800).is_less_than(2100).allow_nil }
    it { is_expected.to define_enum_for(:content_type).with_values(movie: 0, show: 1) }
    it { is_expected.to define_enum_for(:list_state).with_values(wishlist: 0, library: 1) }
  end

  describe "scopes" do
    let!(:user) { create(:user) }
    let!(:movie) { create(:collection_entry, user: user, content_type: :movie, created_at: 2.hours.ago) }
    let!(:show) { create(:collection_entry, user: user, content_type: :show, created_at: 1.hour.ago) }
    let!(:wish) { create(:collection_entry, :wishlist, user: user) }

    it "filters by content type" do
      expect(described_class.movies).to contain_exactly(movie, wish)
      expect(described_class.shows).to contain_exactly(show)
    end

    it "filters library and wishlist membership" do
      expect(described_class.library).to contain_exactly(movie, show)
      expect(described_class.wishlist).to contain_exactly(wish)
    end

    it "orders newest entries first" do
      expect(described_class.recently_added.first).to eq(wish)
    end
  end
end
