# frozen_string_literal: true

class SettingsController < ApplicationController
  DEBRID_KEY_COLUMNS = %w[realdebrid_api_key torbox_api_key].freeze

  before_action :authenticate_user!

  def show
    @user = current_user
  end

  def update
    @user = current_user

    apply_key_removals

    if params[:user][:password].present?
      update_with_password
    else
      update_without_password
    end
  end

  private

  # Blank key fields mean "keep the stored key"; the remove checkbox is the only
  # way to clear one, so an expired key stops overriding the team key.
  def apply_key_removals
    submitted = params[:user]
    return unless submitted

    DEBRID_KEY_COLUMNS.each do |column|
      if submitted["clear_#{column}"].to_s == "1"
        submitted[column] = nil
      elsif submitted[column].blank?
        submitted.delete(column)
      end
    end
  end

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
    realdebrid_key = params.dig(:user, :realdebrid_api_key)
    torbox_key = params.dig(:user, :torbox_api_key)

    if @user.update(settings_params)
      failures = key_verification_failures(realdebrid_key, torbox_key)
      if failures.any?
        redirect_to settings_path, alert: "Settings saved, but #{failures.to_sentence} could not be verified."
      else
        redirect_to settings_path, notice: verification_notice(realdebrid_key, torbox_key)
      end
    else
      render :show, status: :unprocessable_entity
    end
  end

  def key_verification_failures(realdebrid_key, torbox_key)
    failures = []
    if realdebrid_key.present?
      result = RealDebridService.new(realdebrid_key).verify_key
      failures << "the RealDebrid key (#{result.error_message})" if result.failure?
    end
    if torbox_key.present?
      result = TorBoxService.new(torbox_key).verify_key
      failures << "the TorBox key (#{result.error_message})" if result.failure?
    end
    failures
  end

  def verification_notice(realdebrid_key, torbox_key)
    verified = []
    verified << "RealDebrid" if realdebrid_key.present?
    verified << "TorBox" if torbox_key.present?
    return "Settings updated." if verified.empty?

    "Settings updated. #{verified.to_sentence} connection verified."
  end

  def settings_params_with_password
    params.require(:user).permit(:realdebrid_api_key, :torbox_api_key, :debrid_service, :default_language,
      :password, :password_confirmation, :current_password,
      :child_account, :max_rating_age, :child_lock_password, :child_lock_password_confirmation, :child_lock_current_password,
      preferred_languages: [])
  end

  def settings_params
    params.require(:user).permit(:realdebrid_api_key, :torbox_api_key, :debrid_service, :default_language,
      :child_account, :max_rating_age, :child_lock_password, :child_lock_password_confirmation, :child_lock_current_password,
      preferred_languages: [])
  end
end
