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

    if params[:user][:password].present?
      update_with_password
    else
      update_without_password
    end
  end

  private

  def update_with_password
    if @user.update_with_password(settings_params_with_password)
      bypass_sign_in @user
      redirect_to settings_path, notice: "Password updated successfully."
    else
      # Strip password values so they don't render in the form on error
      @user.password = nil
      @user.password_confirmation = nil
      @user.current_password = nil
      render :show, status: :unprocessable_entity
    end
  end

  def update_without_password
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

  def settings_params_with_password
    params.require(:user).permit(:realdebrid_api_key, :default_language, :password, :password_confirmation, :current_password, preferred_languages: [])
  end


  def settings_params
    params.require(:user).permit(:realdebrid_api_key, :default_language, preferred_languages: [])
  end
end
