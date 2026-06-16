# frozen_string_literal: true

class TranscodeController < ApplicationController
  include ActionController::Live

  before_action :authenticate_user!

  # GET /transcode?url=... — FFmpeg transcode proxy
  def stream
    input_url = params[:url]
    if input_url.blank?
      head :bad_request
      return
    end

    headers = {}
    if current_user.has_realdebrid_key?
      headers["Authorization"] = "Bearer #{current_user.realdebrid_api_key}"
    end

    send_stream(type: "video/mp4", filename: "stream.mp4", disposition: "inline") do |stream|
      TranscodeService.transcode_to_fmp4(input_url, headers: headers) do |chunk|
        stream.write(chunk)
      end
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    # Client disconnected
  end
end
