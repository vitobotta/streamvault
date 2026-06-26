# frozen_string_literal: true

class HlsController < ApplicationController
  include StreamUrlValidation

  before_action :authenticate_user!

  # POST /hls/start
  # Params: url, start_seconds, audio_stream, subtitle_stream
  # Returns: { session_id: "...", playlist_url: "/hls/<id>/playlist.m3u8" }
  def start
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url)
      render json: { error: "Invalid stream URL" }, status: :bad_request
      return
    end

    headers = {}
    if current_user.has_realdebrid_key?
      headers["Authorization"] = "Bearer #{current_user.realdebrid_api_key}"
    end

    session = HlsSession.create(
      user_id: current_user.id,
      input_url: input_url,
      headers: headers,
      start_seconds: params[:start_seconds].to_f,
      audio_stream: params[:audio_stream],
      subtitle_stream: params[:subtitle_stream],
      default_language: current_user.default_stream_language,
      preferred_languages: current_user.preferred_stream_languages
    )

    render json: { session_id: session.id, playlist_url: "/hls/#{session.id}/playlist.m3u8" }
  rescue TranscodeService::TranscodeError => e
    Rails.logger.error("[HLS] Failed to start: #{e.message}")
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /hls/:id/playlist.m3u8
  def playlist
    session = HlsSession.find(params[:id])
    unless session && session.user_id == current_user.id
      head :not_found
      return
    end

    unless File.exist?(session.playlist_path)
      head :not_found
      return
    end

    # Read fresh each time — ffmpeg is appending to playlist.m3u8 as it
    # writes segments.  iOS Safari polls the playlist to discover new
    # segments, so a stale cache would stall playback.
    response.headers["Content-Type"] = "application/vnd.apple.mpegurl"
    response.headers["Cache-Control"] = "no-cache"
    # Disable proxy buffering (kamal-proxy / nginx) so playlist updates
    # reach the browser immediately, not buffered in the proxy.
    response.headers["X-Accel-Buffering"] = "no"
    render plain: File.read(session.playlist_path)
  end

  # GET /hls/:id/:segment (e.g. 0.ts, 1.ts)
  def segment
    session = HlsSession.find(params[:id])
    unless session && session.user_id == current_user.id
      head :not_found
      return
    end

    segment_index = params[:segment].to_i
    path = session.segment_path(segment_index)

    unless File.exist?(path)
      head :not_found
      return
    end

    response.headers["Content-Type"] = "video/mp2t"
    response.headers["Cache-Control"] = "no-cache"
    send_file path, disposition: :inline
  end

  # POST /hls/:id/stop
  def stop
    session = HlsSession.find(params[:id])
    # HlsSession.stop removes the session from the registry and reaps
    # ffmpeg + temp dir.  Guard with ownership so a user cannot stop
    # another user's session.
    if session && session.user_id == current_user.id
      HlsSession.stop(params[:id])
    end
    head :ok
  end
end
