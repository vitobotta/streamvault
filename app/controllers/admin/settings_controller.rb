# frozen_string_literal: true

module Admin
  class SettingsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_admin!

    def show
      @settings = AppSetting.current
    end

    def update
      @settings = AppSetting.current
      attributes = settings_params.to_h.compact_blank
      # Blank fields keep the current team key.
      if @settings.update(attributes)
        redirect_to admin_settings_path, notice: "Team settings updated."
      else
        render :show, status: :unprocessable_entity
      end
    end

    private

    def settings_params
      params.require(:app_setting).permit(:realdebrid_api_key, :torbox_api_key)
    end
  end
end
