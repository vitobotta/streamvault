# frozen_string_literal: true

class SettingsController < ApplicationController
  before_action :authenticate_user!

  def show
    @user = current_user
  end

  def update
    @user = current_user

    if @user.update(settings_params)
      # Verify RealDebrid key if provided
      if params[:user][:realdebrid_api_key].present?
        rd = RealDebridService.new(@user.realdebrid_api_key)
        result = rd.verify_key
        if result.success?
          redirect_to settings_path, notice: "Settings updated. RealDebrid connection verified."
        else
          redirect_to settings_path, alert: "Settings saved, but RealDebrid key could not be verified: #{result.error_message}"
        end
      else
        redirect_to settings_path, notice: "Settings updated."
      end
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def settings_params
    params.require(:user).permit(:display_name, :realdebrid_api_key)
  end
end
