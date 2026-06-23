# frozen_string_literal: true

class TranscodeSubtitlesController < ApplicationController
  include StreamUrlValidation

  before_action :authenticate_user!

  def show
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url)
      head :bad_request
      return
    end

    result = TranscodeService.extract_subtitles(
      input_url,
      headers: transcode_headers,
      subtitle_stream: params[:subtitle_stream],
      start_seconds: normalized_start_seconds(params[:start_seconds]),
      duration_seconds: normalized_duration_seconds(params[:duration_seconds])
    )

    case result.status
    when :ok
      send_data result.vtt, type: "text/vtt; charset=utf-8", disposition: "inline"
    when :empty_window
      head :no_content
    when :invalid_stream, :unsupported_track
      render json: { error: "Subtitle track is not available" }, status: :unprocessable_entity
    when :timeout
      render json: { error: "Subtitle extraction timed out" }, status: :gateway_timeout
    else
      render json: { error: "Subtitle extraction failed" }, status: :bad_gateway
    end
  end

  private

  def transcode_headers
    return {} unless current_user.has_realdebrid_key?

    { "Authorization" => "Bearer #{current_user.realdebrid_api_key}" }
  end

  def normalized_start_seconds(value)
    seconds = value.to_f
    seconds.finite? && seconds.positive? ? seconds : 0
  end

  def normalized_duration_seconds(value)
    seconds = value.to_i
    return TranscodeService::SUBTITLE_EXTRACTION_WINDOW_SECONDS unless seconds.positive?

    seconds.clamp(
      TranscodeService::MIN_SUBTITLE_EXTRACTION_WINDOW_SECONDS,
      TranscodeService::MAX_SUBTITLE_EXTRACTION_WINDOW_SECONDS
    )
  end
end
