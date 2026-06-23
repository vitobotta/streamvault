class ApplicationController < ActionController::Base
  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Helper for scoping queries through policies
  def policy_scope(relation)
    authorized_scope(relation, type: :relation)
  end
  helper_method :policy_scope
  helper_method :signups_enabled?

  # Whether new user self-registration is enabled via ENV
  def signups_enabled?
    ENV["ENABLE_SIGNUPS"] == "true"
  end

  # Rescue from authorization failures
  rescue_from ActionPolicy::Unauthorized do |exception|
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "You are not authorized to perform this action." }
      format.json { render json: { error: "Unauthorized" }, status: :forbidden }
    end
  end

  # Rescue from record not found
  rescue_from ActiveRecord::RecordNotFound do |exception|
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "Record not found." }
      format.json { render json: { error: "Not found" }, status: :not_found }
    end
  end
end
