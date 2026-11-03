require 'rails_helper'

RSpec.describe User, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:collection_entries).dependent(:destroy) }
    it { is_expected.to have_many(:playback_progresses).dependent(:destroy) }
    it { is_expected.to have_many(:hls_sessions).dependent(:destroy) }
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

    it "encrypts torbox_api_key" do
      user = create(:user, torbox_api_key: "torbox_secret_123")
      user.reload

      expect(user.torbox_api_key).to eq("torbox_secret_123")
      raw_value = User.connection.select_value(
        "SELECT torbox_api_key FROM users WHERE id = #{user.id}"
      )
      expect(raw_value).not_to eq("torbox_secret_123")
    end
  end

  describe "language defaults" do
    it "defaults preferred_languages to English on create" do
      user = create(:user)
      expect(user.preferred_languages).to eq([ "ENG" ])
      expect(user.default_language).to eq("ENG")
    end

    it "supports Finnish as a preferred stream language" do
      user = create(:user)
      user.update!(preferred_languages: [ "ENG", "FINNISH" ])

      expect(user.reload.preferred_languages).to contain_exactly("ENG", "FINNISH")
      expect(user.preferred_stream_languages).to include("FINNISH")
      expect(user.stream_language_priority).to include("FINNISH")
    end
  end

  describe "debrid credentials" do
    around do |example|
      previous = { "REALDEBRID_API_KEY" => ENV["REALDEBRID_API_KEY"], "TORBOX_API_KEY" => ENV["TORBOX_API_KEY"] }
      ENV.delete("REALDEBRID_API_KEY")
      ENV.delete("TORBOX_API_KEY")
      example.run
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      AppSetting.delete_all
    end

    it "returns true when the account has its own key" do
      user = build(:user, realdebrid_api_key: "some_key")
      expect(user.has_realdebrid_key?).to be true
      expect(user.debrid_key_source).to eq(:user)
    end

    it "returns false when no key is configured" do
      AppSetting.delete_all
      user = build(:user, realdebrid_api_key: nil)
      expect(user.has_realdebrid_key?).to be false
    end

    it "falls back to the administrator's team key" do
      AppSetting.current.update!(realdebrid_api_key: "team_rd_key")
      user = build(:user, realdebrid_api_key: nil)

      expect(user.effective_realdebrid_api_key).to eq("team_rd_key")
      expect(user.has_realdebrid_key?).to be true
      expect(user.debrid_key_source).to eq(:global)
    end

    it "falls back to the environment when no team key is set" do
      ENV["REALDEBRID_API_KEY"] = "env_rd_key"
      user = build(:user, realdebrid_api_key: nil)

      expect(user.effective_realdebrid_api_key).to eq("env_rd_key")
      expect(user.debrid_key_source).to eq(:environment)
    end

    it "prefers the account key over the team and environment keys" do
      AppSetting.current.update!(realdebrid_api_key: "team_rd_key")
      ENV["REALDEBRID_API_KEY"] = "env_rd_key"
      user = build(:user, realdebrid_api_key: "own_key")

      expect(user.effective_realdebrid_api_key).to eq("own_key")
    end

    it "uses the TorBox key when TorBox is selected" do
      AppSetting.current.update!(torbox_api_key: "team_tb_key")
      user = build(:user, debrid_service: "torbox", torbox_api_key: nil)

      expect(user.effective_debrid_service).to eq("torbox")
      expect(user.effective_debrid_api_key).to eq("team_tb_key")
      expect(user.debrid_configured?).to be true
    end

    it "uses both keys and lists the selected service first" do
      user = build(:user, debrid_service: "torbox", realdebrid_api_key: "own_rd_key", torbox_api_key: "own_tb_key")

      expect(user.debrid_configured?).to be true
      expect(user.debrid_credentials).to eq([ [ "torbox", "own_tb_key" ], [ "realdebrid", "own_rd_key" ] ])
    end

    it "uses a key for the other service when the selected one has none" do
      user = build(:user, debrid_service: "torbox", realdebrid_api_key: "own_rd_key")

      expect(user.has_realdebrid_key?).to be true
      expect(user.debrid_configured?).to be true
      expect(user.debrid_credentials).to eq([ [ "realdebrid", "own_rd_key" ] ])
    end
  end

  describe "child account settings" do
    let(:user) { create(:user) }

    def enable_child_account!(account, password: "lock-1234", max_age: 13)
      account.update!(child_account: true, max_rating_age: max_age,
        child_lock_password: password, child_lock_password_confirmation: password)
    end

    describe "enabling child status" do
      it "requires a child lock password" do
        user.update(child_account: true, max_rating_age: 13)

        expect(user.errors[:child_lock_password]).to include("must be set to enable child accounts")
        expect(user.reload.child_account).to eq(false)
      end

      it "requires a max rating age" do
        user.update(child_account: true, child_lock_password: "lock-1234")

        expect(user.errors[:max_rating_age]).to include("must be set for child accounts")
      end

      it "rejects a too-short child lock password" do
        user.update(child_account: true, max_rating_age: 13, child_lock_password: "abc")

        expect(user.errors[:child_lock_password]).to include("must be at least 4 characters")
      end

      it "rejects a mismatched password confirmation" do
        user.update(child_account: true, max_rating_age: 13,
          child_lock_password: "lock-1234", child_lock_password_confirmation: "other-1234")

        expect(user.errors[:child_lock_password_confirmation]).to include("doesn't match")
      end

      it "stores only a digest of the child lock password" do
        enable_child_account!(user)
        user.reload

        expect(user.child_account).to eq(true)
        expect(user.max_rating_age).to eq(13)
        expect(user.child_lock_password_digest).to be_present
        expect(user.child_lock_password_digest).not_to include("lock-1234")
        expect(user.valid_child_lock_password?("lock-1234")).to eq(true)
        expect(user.valid_child_lock_password?("wrong")).to eq(false)
        expect(user.valid_child_lock_password?(nil)).to eq(false)
      end

      it "requires the max rating age to stay within 0..18" do
        user.update(child_account: true, max_rating_age: 21, child_lock_password: "lock-1234")

        expect(user.errors[:max_rating_age]).to include("must be between 0 and 18")
      end
    end

    describe "protected changes" do
      before { enable_child_account!(user) }

      it "refuses to turn child status off without the current password" do
        user.update(child_account: false)

        expect(user.errors[:child_lock_current_password]).to be_present
        expect(user.reload.child_account).to eq(true)
      end

      it "refuses to turn child status off with a wrong password" do
        user.update(child_account: false, child_lock_current_password: "wrong")

        expect(user.errors[:child_lock_current_password]).to include("is incorrect")
        expect(user.reload.child_account).to eq(true)
      end

      it "turns child status off with the correct password" do
        user.update!(child_account: false, child_lock_current_password: "lock-1234")

        expect(user.reload.child_account).to eq(false)
      end

      it "refuses to change the max rating age without the current password" do
        user.update(max_rating_age: 18)

        expect(user.errors[:child_lock_current_password]).to be_present
        expect(user.reload.max_rating_age).to eq(13)
      end

      it "changes the max rating age with the correct password" do
        user.update!(max_rating_age: 8, child_lock_current_password: "lock-1234")

        expect(user.reload.max_rating_age).to eq(8)
      end

      it "refuses to replace the lock password without the current password" do
        user.update(child_lock_password: "new-lock-1234")

        expect(user.errors[:child_lock_current_password]).to be_present
        expect(user.reload.valid_child_lock_password?("new-lock-1234")).to eq(false)
      end

      it "replaces the lock password with the correct current password" do
        user.update!(child_lock_password: "new-lock-1234", child_lock_current_password: "lock-1234")

        expect(user.reload.valid_child_lock_password?("new-lock-1234")).to eq(true)
        expect(user.valid_child_lock_password?("lock-1234")).to eq(false)
      end

      it "allows unrelated settings changes without the lock password" do
        user.update!(display_name: "Kiddo")

        expect(user.reload.display_name).to eq("Kiddo")
      end

      it "allows re-enabling child status with the kept lock password" do
        user.update!(child_account: false, child_lock_current_password: "lock-1234")
        user.update!(child_account: true, max_rating_age: 13)

        expect(user.reload.child_account).to eq(true)
      end
    end

    describe "non-child accounts" do
      it "are unaffected by the child lock rules" do
        expect(user.update(display_name: "Regular", child_lock_current_password: "garbage")).to eq(true)
        expect(user.update(max_rating_age: nil)).to eq(true)
      end
    end
  end
end
