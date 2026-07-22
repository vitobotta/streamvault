require "rails_helper"

RSpec.describe CollectionMembershipService do
  let(:user) { create(:user) }

  describe ".add_to_library" do
    it "adds the library entry and removes matching wishlist membership atomically" do
      wishlist_entry = create(:wishlist_entry, user: user, imdb_id: "tt1375666")

      result = described_class.add_to_library(
        user: user,
        attributes: {
          content_type: "movie",
          imdb_id: "tt1375666",
          title: "Inception",
          poster_url: "https://image.test/inception.jpg",
          year: 2010
        }
      )

      expect(result).to be_success
      expect(result.data).to be_persisted
      expect(WishlistEntry.exists?(wishlist_entry.id)).to be(false)
    end

    it "returns validation errors without removing wishlist membership" do
      wishlist_entry = create(:wishlist_entry, user: user, imdb_id: "tt1375666")

      result = described_class.add_to_library(user: user, attributes: { imdb_id: "tt1375666" })

      expect(result).to be_failure
      expect(WishlistEntry.exists?(wishlist_entry.id)).to be(true)
    end
  end

  describe ".move_to_library" do
    it "refreshes an existing library entry before removing the wishlist entry" do
      library_entry = create(:library_entry, user: user, imdb_id: "tt1375666", title: "Old title")
      wishlist_entry = create(:wishlist_entry, user: user, imdb_id: "tt1375666", title: "Inception", year: 2010)

      result = described_class.move_to_library(user: user, wishlist_entry: wishlist_entry)

      expect(result).to be_success
      expect(library_entry.reload.title).to eq("Inception")
      expect(WishlistEntry.exists?(wishlist_entry.id)).to be(false)
    end
  end
end
