require "rails_helper"

RSpec.describe "Admin settings", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:member) { create(:user) }

  describe "GET /admin/settings" do
    it "redirects non-administrators" do
      sign_in member

      get admin_settings_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("administrators")
    end

    it "shows the team key form to administrators without revealing stored keys" do
      AppSetting.current.update!(realdebrid_api_key: "TEAM_SECRET_DO_NOT_LEAK")
      sign_in admin

      get admin_settings_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Team settings")
      expect(response.body).not_to include("TEAM_SECRET_DO_NOT_LEAK")
    end
  end

  describe "PATCH /admin/settings" do
    it "does not let a member change the team keys" do
      AppSetting.current.update!(realdebrid_api_key: "existing_team_key")
      sign_in member

      patch admin_settings_path, params: { app_setting: { realdebrid_api_key: "replaced_by_member" } }

      expect(response).to redirect_to(root_path)
      expect(AppSetting.current.realdebrid_api_key).to eq("existing_team_key")
    end

    before { sign_in admin }

    it "stores team keys encrypted and uses them for members without their own key" do
      patch admin_settings_path, params: { app_setting: { realdebrid_api_key: "team_rd_key", torbox_api_key: "team_tb_key" } }

      expect(response).to redirect_to(admin_settings_path)
      settings = AppSetting.current
      expect(settings.realdebrid_api_key).to eq("team_rd_key")
      expect(settings.torbox_api_key).to eq("team_tb_key")
      raw = AppSetting.connection.select_value(
        "SELECT realdebrid_api_key FROM app_settings WHERE id = #{settings.id}"
      )
      expect(raw).not_to eq("team_rd_key")

      member_without_key = create(:user)
      expect(member_without_key.effective_realdebrid_api_key).to eq("team_rd_key")
      expect(member_without_key.debrid_key_source).to eq(:global)
    end

    it "keeps existing team keys when the fields are blank" do
      AppSetting.current.update!(realdebrid_api_key: "existing_team_key")

      patch admin_settings_path, params: { app_setting: { realdebrid_api_key: "", torbox_api_key: "" } }

      expect(AppSetting.current.realdebrid_api_key).to eq("existing_team_key")
    end
  end
end
