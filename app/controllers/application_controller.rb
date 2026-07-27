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
end
