# frozen_string_literal: true

class TranscodeController < ApplicationController
  include ActionController::Live
  include StreamUrlValidation

  MAX_START_SECONDS = 24 * 60 * 60

  before_action :authenticate_user!

  # GET /transcode?url=...&start_seconds=... — FFmpeg transcode proxy
  def stream
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      head :bad_request
      return
    end

    start_seconds = normalized_start_seconds(params[:start_seconds])

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

    playback_id = normalized_playback_id(params[:playback_id])
    load_id = normalized_load_id(params[:load_id])
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    written_bytes = 0
    outcome = "complete"

    begin
      TranscodeService.transcode_to_fmp4(
        input_url,
        headers: headers,
        start_seconds: start_seconds,
        audio_stream: params[:audio_stream],
        subtitle_stream: params[:subtitle_stream],
        default_language: current_user.default_stream_language,
        preferred_languages: current_user.preferred_stream_languages,
        remux: params[:remux] == "1",
        telemetry_id: playback_id
      ) do |chunk|
        response.stream.write(chunk)
        written_bytes += chunk.bytesize
      end
    rescue TranscodeService::TranscodeError => e
      outcome = "ffmpeg_error"
      Rails.logger.error("[Transcode] playback_id=#{playback_id} #{e.message}")
      if response.stream.closed? || response.committed?
        # Data was already sent (mid-stream stall).  Headers are committed;
        # we cannot rewrite the response.  The frontend watchdog will detect
        # the stall and reconnect from the current playback position.
      else
        # No data has been written yet — headers are not committed.
        # Replace with an error response the browser can actually show.
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
        response.headers.delete("Content-Disposition")
        response.headers.delete("Cache-Control")
        response.headers.delete("Accept-Ranges")
        response.status = :bad_gateway
        response.stream.write("Unable to start stream: #{e.message}")
      end
    rescue ActionController::Live::ClientDisconnected, IOError => e
      outcome = "client_disconnected"
      Rails.logger.info("[TranscodeStream] playback_id=#{playback_id} load_id=#{load_id} client_disconnect=#{e.class}")
    ensure
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      Rails.logger.info(
        "[TranscodeStream] playback_id=#{playback_id} load_id=#{load_id} " \
        "remux=#{params[:remux] == '1'} start_seconds=#{start_seconds.round(2)} " \
        "outcome=#{outcome} written_bytes=#{written_bytes} elapsed=#{elapsed.round(2)}s"
      )
      response.stream.close
    end
  end

  private

  def normalized_playback_id(value)
    sanitized = value.to_s.gsub(/[^a-zA-Z0-9_-]/, "").first(80)
    sanitized.presence || "unknown"
  end

  def normalized_load_id(value)
    value.to_i.clamp(0, 1_000_000)
  end

  def normalized_start_seconds(value)
    seconds = value.to_f
    return 0 unless seconds.finite? && seconds.positive?

    [ seconds, MAX_START_SECONDS ].min
  end
end
