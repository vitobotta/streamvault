require 'rails_helper'

RSpec.describe User, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:library_entries).dependent(:destroy) }
    it { is_expected.to have_many(:watch_history_entries).dependent(:destroy) }
    it { is_expected.to have_many(:wishlist_entries).dependent(:destroy) }
    it { is_expected.to have_many(:episode_progresses).dependent(:destroy) }
  end

  describe "encryption" do
    it "encrypts realdebrid_api_key" do
      user = create(:user, realdebrid_api_key: "test_api_key_123")
      user.reload

      expect(user.realdebrid_api_key).to eq("test_api_key_123")
      raw_value = User.connection.select_value(
        "SELECT realdebrid_api_key FROM users WHERE id = #{user.id}"
      )
      expect(raw_value).not_to eq("test_api_key_123")
    end
  end

  describe "language defaults" do
    it "defaults preferred_languages to English on create" do
      user = create(:user)
      expect(user.preferred_languages).to eq(["ENG"])
      expect(user.default_language).to eq("ENG")
    end
  end

  describe "#has_realdebrid_key?" do
    it "returns true when key is present" do
      user = build(:user, realdebrid_api_key: "some_key")
      expect(user.has_realdebrid_key?).to be true
    end

    it "returns false when key is nil" do
      user = build(:user, realdebrid_api_key: nil)
      expect(user.has_realdebrid_key?).to be false
    end

    it "returns false when key is blank" do
      user = build(:user, realdebrid_api_key: "")
      expect(user.has_realdebrid_key?).to be false
    end
  end
end
