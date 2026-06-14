require 'rails_helper'

RSpec.describe LibraryEntryPolicy do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:entry) { create(:library_entry, user: user) }
  let(:other_entry) { create(:library_entry, user: other_user) }

  describe "#show?" do
    it "allows owner to view" do
      policy = described_class.new(entry, user: user)
      expect(policy.show?).to be true
    end

    it "denies non-owner" do
      policy = described_class.new(entry, user: other_user)
      expect(policy.show?).to be false
    end
  end

  describe "#create?" do
    it "allows any authenticated user" do
      policy = described_class.new(entry, user: user)
      expect(policy.create?).to be true
    end
  end

  describe "#update?" do
    it "allows owner" do
      policy = described_class.new(entry, user: user)
      expect(policy.update?).to be true
    end

    it "denies non-owner" do
      policy = described_class.new(entry, user: other_user)
      expect(policy.update?).to be false
    end
  end

  describe "#destroy?" do
    it "allows owner" do
      policy = described_class.new(entry, user: user)
      expect(policy.destroy?).to be true
    end

    it "denies non-owner" do
      policy = described_class.new(entry, user: other_user)
      expect(policy.destroy?).to be false
    end
  end

  describe "scope" do
    before { entry; other_entry }

    it "returns only user's entries" do
      scope = described_class.new(entry, user: user).apply_scope(LibraryEntry.all, type: :relation)
      expect(scope).to include(entry)
      expect(scope).not_to include(other_entry)
    end
  end
end

RSpec.describe WatchHistoryEntryPolicy do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:entry) { create(:watch_history_entry, user: user) }

  describe "#show?" do
    it "allows owner" do
      policy = described_class.new(entry, user: user)
      expect(policy.show?).to be true
    end

    it "denies non-owner" do
      policy = described_class.new(entry, user: other_user)
      expect(policy.show?).to be false
    end
  end

  describe "#clear_all?" do
    it "allows any user" do
      policy = described_class.new(entry, user: user)
      expect(policy.clear_all?).to be true
    end
  end

  describe "scope" do
    let!(:other_entry) { create(:watch_history_entry, user: other_user) }

    it "returns only user's entries" do
      scope = described_class.new(entry, user: user).apply_scope(WatchHistoryEntry.all, type: :relation)
      expect(scope).to include(entry)
      expect(scope).not_to include(other_entry)
    end
  end
end

RSpec.describe WishlistEntryPolicy do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:entry) { create(:wishlist_entry, user: user) }

  describe "#move_to_library?" do
    it "allows owner" do
      policy = described_class.new(entry, user: user)
      expect(policy.move_to_library?).to be true
    end

    it "denies non-owner" do
      policy = described_class.new(entry, user: other_user)
      expect(policy.move_to_library?).to be false
    end
  end
end

RSpec.describe EpisodeProgressPolicy do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:progress) { create(:episode_progress, user: user) }

  describe "scope" do
    let!(:other_progress) { create(:episode_progress, user: other_user) }

    it "returns only user's progress" do
      scope = described_class.new(progress, user: user).apply_scope(EpisodeProgress.all, type: :relation)
      expect(scope).to include(progress)
      expect(scope).not_to include(other_progress)
    end
  end
end
