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
      attributes = submitted_keys

      # A mistyped replacement would break every account that relies on the team
      # key, so a new value is verified before it replaces the working one.
      failures = key_verification_failures(attributes)
      if failures.any?
        redirect_to admin_settings_path,
          alert: "Not saved: #{failures.values.to_sentence} could not be verified. The previous key is still in use."
      elsif @settings.update(attributes)
        redirect_to admin_settings_path, notice: "Team settings updated."
      else
        render :show, status: :unprocessable_entity
      end
    end

    private

    # Blank fields keep the current team key; the remove checkbox clears it so
    # the installation falls back to the environment.
    def submitted_keys
      submitted = settings_params.to_h
      attributes = submitted.slice(*AppSetting::KEY_COLUMNS).compact_blank
      AppSetting::KEY_COLUMNS.each do |column|
        attributes[column] = nil if submitted["clear_#{column}"].to_s == "1"
      end
      attributes
    end

    def key_verification_failures(attributes)
      failures = {}
      if attributes[:realdebrid_api_key].present?
        result = RealDebridService.new(attributes[:realdebrid_api_key]).verify_key
        failures[:realdebrid_api_key] = "the RealDebrid key (#{result.error_message})" if result.failure?
      end
      if attributes[:torbox_api_key].present?
        result = TorBoxService.new(attributes[:torbox_api_key]).verify_key
        failures[:torbox_api_key] = "the TorBox key (#{result.error_message})" if result.failure?
      end
      failures
    end

    def settings_params
      params.require(:app_setting).permit(:realdebrid_api_key, :torbox_api_key,
        :clear_realdebrid_api_key, :clear_torbox_api_key)
    end
  end
end
