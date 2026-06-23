# frozen_string_literal: true

class TranscodeTracksController < ApplicationController
  include StreamUrlValidation

  before_action :authenticate_user!

  def show
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url)
      render json: { audio: [], subtitles: [] }, status: :bad_request
      return
    end

    tracks = TranscodeService.probe_media_tracks(input_url, headers: transcode_headers)
    external_subtitles = ExternalSubtitleService.search(
      imdb_id: params[:imdb_id],
      type: params[:type],
      season: params[:season],
      episode: params[:episode],
      title: params[:title],
      filename: params[:filename],
      preferred_languages: current_user.preferred_stream_languages,
      default_language: current_user.default_stream_language
    )

    subtitles = TranscodeService.selectable_subtitle_tracks(tracks[:subtitles] + external_subtitles)
    render json: tracks.merge(subtitles: subtitles)
  end

  private

  def transcode_headers
    return {} unless current_user.has_realdebrid_key?

    { "Authorization" => "Bearer #{current_user.realdebrid_api_key}" }
  end
end
