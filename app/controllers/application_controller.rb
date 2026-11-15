class ApplicationController < ActionController::Base
  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :signups_enabled?

  # Whether new user self-registration is enabled via ENV
  def signups_enabled?
    ENV["ENABLE_SIGNUPS"] == "true"
  end


  # Rescue from record not found
  rescue_from ActiveRecord::RecordNotFound do |exception|
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "Record not found." }
      format.json { render json: { error: "Not found" }, status: :not_found }
    end
  end

  # Rating-limit policy for child accounts (no-op for regular accounts).
  helper_method :debrid_access_configured?

  # True when playback can resolve streams: the account has a key (own, team,
  # or environment), or a shared AIOStreams instance supplies its own debrid
  # credentials.
  def debrid_access_configured?
    current_user&.debrid_configured? || StreamProvider.keyless_provider_available?
  end

  private

  def parental_content_policy
    ParentalControls::ContentPolicy.new(current_user)
  end

  def require_admin!
    return if current_user&.admin?

    redirect_to root_path, alert: "That page is restricted to administrators."
  end
end
