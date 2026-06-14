require 'rails_helper'

RSpec.describe "Settings", type: :request do
  let(:user) { create(:user) }

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

    it "updates display name" do
      patch settings_path, params: { user: { display_name: "New Name" } }
      expect(response).to redirect_to(settings_path)
      expect(user.reload.display_name).to eq("New Name")
    end

    it "updates RealDebrid key and verifies" do
      stub_request(:get, "https://api.real-debrid.com/rest/1.0/user")
        .to_return(status: 200, body: { "username" => "testuser" }.to_json, headers: { 'Content-Type' => 'application/json' })

      patch settings_path, params: { user: { realdebrid_api_key: "new_key_123" } }
      expect(response).to redirect_to(settings_path)
      expect(user.reload.realdebrid_api_key).to eq("new_key_123")
    end
  end
end
