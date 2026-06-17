# frozen_string_literal: true

class TranscodeController < ApplicationController
  include ActionController::Live

  before_action :authenticate_user!

  # GET /transcode?url=...&start_seconds=... — FFmpeg transcode proxy
  def stream
    input_url = params[:url]
    if input_url.blank?
      head :bad_request
      return
    end

    start_seconds = params[:start_seconds].to_f

    headers = {}
    if current_user.has_realdebrid_key?
      headers["Authorization"] = "Bearer #{current_user.realdebrid_api_key}"
    end

    # Set streaming headers — not committed until the first response.stream.write.
    # If TranscodeError fires before any data is written, we can still
    # replace them with an error response below.
    response.headers["Content-Type"] = "video/mp4"
    response.headers["Content-Disposition"] = "inline; filename=\"stream.mp4\""
    response.headers["Cache-Control"] = "no-cache"
    response.headers["Accept-Ranges"] = "none"
    # Disable proxy buffering (kamal-proxy / nginx) so ffmpeg output
    # reaches the browser immediately, not buffered in the proxy.
    response.headers["X-Accel-Buffering"] = "no"

    begin
      TranscodeService.transcode_to_fmp4(input_url, headers: headers, start_seconds: start_seconds) do |chunk|
        response.stream.write(chunk)
      end
    rescue TranscodeService::TranscodeError => e
      Rails.logger.error("[Transcode] #{e.message}")
      # No data has been written yet — headers are not committed.
      # Replace with an error response the browser can actually show.
      response.headers["Content-Type"] = "text/plain; charset=utf-8"
      response.headers.delete("Content-Disposition")
      response.headers.delete("Cache-Control")
      response.headers.delete("Accept-Ranges")
      response.status = :bad_gateway
      response.stream.write("Unable to start stream: #{e.message}")
    rescue ActionController::Live::ClientDisconnected, IOError
      # Client disconnected — ffmpeg cleanup handled by TranscodeService ensure
    ensure
      response.stream.close
    end
  end
end
