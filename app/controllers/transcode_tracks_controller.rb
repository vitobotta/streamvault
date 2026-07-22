# frozen_string_literal: true

class TranscodeTracksController < ApplicationController
  include StreamUrlValidation


  before_action :authenticate_user!

  def show
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { audio: [], subtitles: [] }, status: :bad_request
      return
    end

    result = MediaProfileService.new(
      input_url: input_url,
      filename: params[:filename],
      headers: transcode_headers,
      subtitle_search: {
        imdb_id: params[:imdb_id],
        type: params[:type],
        season: params[:season],
        episode: params[:episode],
        title: params[:title],
        filename: params[:filename],
        preferred_languages: current_user.preferred_stream_languages,
        default_language: current_user.default_stream_language
      }
    ).call

    unless result.success?
      render json: { audio: [], subtitles: [], error: result.error_message }, status: :bad_gateway
      return
    end

    render json: result.data.merge(
      direct_stream_url: direct_stream_url(input_url),
      remux_direct_url: remux_direct_url(input_url)
    )
  end

  # Return a keyframe-aligned remux start plus the short local pre-roll
  # the browser must skip to land on the exact requested position.
  def seek
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { copy_safe: false }, status: :bad_request
      return
    end

    plan = TranscodeService.probe_remux_seek(
      input_url,
      target_seconds: params[:start_seconds],
      headers: transcode_headers
    )

    if plan
      render json: plan.merge(copy_safe: true)
    else
      render json: { copy_safe: false }
    end
  end

  private

  def transcode_headers
    return {} unless current_user.has_realdebrid_key?

    { "Authorization" => "Bearer #{current_user.realdebrid_api_key}" }
  end

  def direct_stream_url(input_url)
    "/direct_stream?url=#{CGI.escape(input_url)}"
  end

  def remux_direct_url(input_url)
    "/transcode?url=#{CGI.escape(input_url)}&remux=1"
  end
end
