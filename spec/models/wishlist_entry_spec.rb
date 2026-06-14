require 'rails_helper'

RSpec.describe WishlistEntry, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:wishlist_entry) }

    it { is_expected.to validate_presence_of(:imdb_id) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_uniqueness_of(:imdb_id).scoped_to(:user_id).with_message("already in your wishlist") }
    it { is_expected.to validate_numericality_of(:year).is_greater_than(1800).is_less_than(2100).allow_nil }

    it { is_expected.to define_enum_for(:content_type).with_values(movie: 0, show: 1) }
  end

  describe "scopes" do
    let!(:user) { create(:user) }
    let!(:movie) { create(:wishlist_entry, user: user, content_type: :movie) }
    let!(:show) { create(:wishlist_entry, user: user, content_type: :show) }

    describe ".by_type" do
      it "returns entries of the specified type" do
        expect(described_class.by_type(:movie)).to include(movie)
        expect(described_class.by_type(:movie)).not_to include(show)
      end
    end

    describe ".recently_added" do
      it "orders by created_at desc" do
        expect(described_class.recently_added.first).to eq(show)
      end
    end
  end
end
