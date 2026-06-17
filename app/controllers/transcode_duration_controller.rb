# frozen_string_literal: true

# Separate controller for the duration probe endpoint.
# This MUST NOT include ActionController::Live — that module runs every
# action in a separate thread where Devise's throw(:warden) is not caught,
# causing an UncaughtThrowError when authentication fails.
class TranscodeDurationController < ApplicationController
  before_action :authenticate_user!

  # GET /transcode/duration?url=... — probe file duration via ffprobe
  def show
    input_url = params[:url]
    if input_url.blank?
      render json: { duration: 0 }, status: :bad_request
      return
    end

    headers = {}
    if current_user.has_realdebrid_key?
      headers["Authorization"] = "Bearer #{current_user.realdebrid_api_key}"
    end

    dur = TranscodeService.probe_duration(input_url, headers: headers)
    render json: { duration: dur }
  end
end
