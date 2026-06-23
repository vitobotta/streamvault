# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  before_action :redirect_when_signups_disabled, only: [ :new, :create ]

  private

  def redirect_when_signups_disabled
    return if signups_enabled?

    redirect_to new_session_path(resource_name), alert: "New signups are disabled."
  end

  def signups_enabled?
    ENV["ENABLE_SIGNUPS"] == "true"
  end
end
