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

    render json: TranscodeService.probe_media_tracks(input_url, headers: transcode_headers)
  end

  private

  def transcode_headers
    return {} unless current_user.has_realdebrid_key?

    { "Authorization" => "Bearer #{current_user.realdebrid_api_key}" }
  end
end
