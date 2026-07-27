# frozen_string_literal: true

class TranscodeTracksController < ApplicationController
  include ResolvedSourceAccess


  before_action :authenticate_user!

  def show
    source = resolved_source

    result = MediaProfileService.new(
      input_url: source.url,
      filename: source.filename,
      headers: source_headers,
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

    render json: result.data.to_h.merge(
      direct_stream_url: direct_stream_url,
      remux_direct_url: remux_direct_url
    )
  rescue ResolvedSource::Invalid
    render json: { audio: [], subtitles: [] }, status: :bad_request
  end

  # Return a keyframe-aligned remux start plus the short local pre-roll
  # the browser must skip to land on the exact requested position.
  def seek
    source = resolved_source

    plan = Media::Probe.remux_seek(
      source.url,
      target_seconds: params[:start_seconds],
      headers: source_headers
    )

    if plan
      render json: plan.merge(copy_safe: true)
    else
      render json: { copy_safe: false }
    end
  rescue ResolvedSource::Invalid
    render json: { copy_safe: false }, status: :bad_request
  end

  private


  def direct_stream_url
    direct_stream_path(source: params[:source])
  end

  def remux_direct_url
    transcode_stream_path(source: params[:source], remux: 1)
  end
end
