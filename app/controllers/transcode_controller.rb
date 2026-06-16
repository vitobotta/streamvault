# frozen_string_literal: true

# Separate controller for FFmpeg transcoding — uses ActionController::Live
# which would interfere with normal controller lifecycle if mixed in.
class TranscodeController < ApplicationController
  include ActionController::Live

  before_action :authenticate_user!

  # GET /transcode?url=... — FFmpeg transcode proxy
  # Remuxes MKV → fMP4, transcodes audio to AAC, copies video
  def stream
    input_url = params[:url]
    if input_url.blank?
      head :bad_request
      return
    end

    send_stream(type: "video/mp4", disposition: "inline") do |stream|
      TranscodeService.transcode_to_fmp4(input_url) do |chunk|
        stream.write(chunk)
      end
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    # Client disconnected
  end
end
