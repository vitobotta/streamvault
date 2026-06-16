# frozen_string_literal: true

class SettingsController < ApplicationController
  before_action :authenticate_user!

  def show
    @user = current_user
  end

  def update
    @user = current_user

    # Preserve existing RD key if not provided
    if params[:user][:realdebrid_api_key].blank?
      params[:user].delete(:realdebrid_api_key)
    end

    if @user.update(settings_params)
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
    params.require(:user).permit(:realdebrid_api_key, :default_language, preferred_languages: [])
  end
end
