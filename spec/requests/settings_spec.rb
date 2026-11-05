require 'rails_helper'

RSpec.describe "Settings", type: :request do
  let(:user) { create(:user) }

  before do
    stub_request(:get, /www\.omdbapi\.com/)
      .to_return(status: 200, body: { "Response" => "False" }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe "GET /settings" do
    context "when not authenticated" do
      it "redirects to login" do
        get settings_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get settings_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "PATCH /settings" do
    before { sign_in user }

    it "updates RealDebrid key and verifies" do
      stub_request(:get, "https://api.real-debrid.com/rest/1.0/user")
        .to_return(status: 200, body: { "username" => "testuser" }.to_json, headers: { 'Content-Type' => 'application/json' })

      patch settings_path, params: { user: { realdebrid_api_key: "new_key_123" } }
      expect(response).to redirect_to(settings_path)
      expect(user.reload.realdebrid_api_key).to eq("new_key_123")
    end

    it "preserves existing RD key when blank" do
      user.update!(realdebrid_api_key: "existing_key")
      patch settings_path, params: { user: { realdebrid_api_key: "" } }
      expect(user.reload.realdebrid_api_key).to eq("existing_key")
    end

    it "removes the saved key when the remove checkbox is submitted" do
      user.update!(realdebrid_api_key: "expired_key")

      patch settings_path, params: { user: { realdebrid_api_key: "", clear_realdebrid_api_key: "1" } }

      expect(response).to redirect_to(settings_path)
      expect(user.reload.realdebrid_api_key).to be_nil
    end

    it "updates preferred languages" do
      patch settings_path, params: { user: { preferred_languages: [ "ENG", "FRENCH" ] } }
      expect(response).to redirect_to(settings_path)
      expect(user.reload.preferred_languages).to include("ENG", "FRENCH")
    end

    it "updates the TorBox key and service" do
      stub_request(:get, "https://api.torbox.app/v1/api/user/me")
        .to_return(status: 200, body: { "success" => true }.to_json, headers: { "Content-Type" => "application/json" })

      patch settings_path, params: { user: { torbox_api_key: "new_torbox_key", debrid_service: "torbox" } }

      expect(response).to redirect_to(settings_path)
      expect(user.reload.torbox_api_key).to eq("new_torbox_key")
      expect(user.debrid_service).to eq("torbox")
      expect(flash[:notice]).to include("TorBox")
    end

    it "preserves an existing TorBox key when the field is blank" do
      user.update!(torbox_api_key: "existing_torbox_key")

      patch settings_path, params: { user: { torbox_api_key: "" } }

      expect(user.reload.torbox_api_key).to eq("existing_torbox_key")
    end

    it "shows when a team key will be used" do
      AppSetting.current.update!(realdebrid_api_key: "team_rd_key")

      get settings_path

      expect(response.body).to include("Using the team RealDebrid key.")
      expect(response.body).not_to include("team_rd_key")
    end
  end

  describe "RD key exposure (SEC-08)" do
    before { sign_in user }

    it "does not leak the plaintext RD key in the settings page body" do
      user.update!(realdebrid_api_key: "SECRET_KEY_DO_NOT_LEAK")
      get settings_path
      expect(response.body).not_to include("SECRET_KEY_DO_NOT_LEAK")
    end
  end
end
