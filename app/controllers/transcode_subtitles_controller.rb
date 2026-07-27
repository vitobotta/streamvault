# frozen_string_literal: true

class TranscodeSubtitlesController < ApplicationController
  include ResolvedSourceAccess

  before_action :authenticate_user!

  def show
    source = resolved_source

    result = subtitle_result(source)

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
  rescue ResolvedSource::Invalid
    head :bad_request
  end

  private


  def normalized_start_seconds(value)
    seconds = value.to_f
    seconds.finite? && seconds.positive? ? seconds : 0
  end

  def normalized_duration_seconds(value)
    seconds = value.to_i
    return Media::Subtitles::DEFAULT_WINDOW_SECONDS unless seconds.positive?

    seconds.clamp(
      Media::Subtitles::MIN_WINDOW_SECONDS,
      Media::Subtitles::MAX_WINDOW_SECONDS
    )
  end

  def subtitle_result(source)
    if ExternalSubtitleService.external_stream?(params[:subtitle_stream])
      return ExternalSubtitleService.extract_subtitles(
        params[:subtitle_stream],
        start_seconds: normalized_start_seconds(params[:start_seconds]),
        duration_seconds: normalized_duration_seconds(params[:duration_seconds])
      )
    end

    Media::Subtitles.extract(
      source.url,
      headers: source_headers,
      subtitle_stream: params[:subtitle_stream],
      start_seconds: normalized_start_seconds(params[:start_seconds]),
      duration_seconds: normalized_duration_seconds(params[:duration_seconds])
    )
  end
end
