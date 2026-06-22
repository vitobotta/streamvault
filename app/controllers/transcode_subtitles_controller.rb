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

    subtitles = TranscodeService.extract_subtitles_to_vtt(
      input_url,
      headers: transcode_headers,
      subtitle_stream: params[:subtitle_stream],
      start_seconds: normalized_start_seconds(params[:start_seconds])
    )

    send_data subtitles.presence || "WEBVTT\n\n", type: "text/vtt; charset=utf-8", disposition: "inline"
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
end
