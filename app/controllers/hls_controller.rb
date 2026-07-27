# frozen_string_literal: true

class HlsController < ApplicationController
  include ResolvedSourceAccess

  # The start/stop endpoints require an authenticated user (they
  # access current_user and the RealDebrid API key).  The playlist
  # and segment endpoints must NOT require authentication — iOS
  # Safari's <video> element fetches media resources without sending
  # session cookies, so cookie-based auth would reject those requests
  # with 403.  Instead, the session ID (128 bits of entropy) acts as
  # an unguessable bearer token, and the playlist/segment actions
  # rely on the session ID alone for authorisation.
  before_action :authenticate_user!, only: %i[start stop]

  # POST /hls/start
  # Params: url, start_seconds, audio_stream, subtitle_stream
  # Returns: { session_id: "...", playlist_url: "/hls/<id>/playlist.m3u8" }
  def start
    source = resolved_source

    headers = source_headers

    session = HlsSessionManager.create(
      user_id: current_user.id,
      input_url: source.url,
      headers: headers,
      start_seconds: params[:start_seconds].to_f,
      audio_stream: params[:audio_stream],
      subtitle_stream: params[:subtitle_stream],
      default_language: current_user.default_stream_language,
      preferred_languages: current_user.preferred_stream_languages
    )
    playback_id = params[:playback_id].to_s.gsub(/[^a-zA-Z0-9_-]/, "").first(80).presence || "unknown"
    Rails.logger.info("[HLS] playback_id=#{playback_id} session_id=#{session.session_id} started")

    render json: {
      session_id: session.session_id,
      playlist_url: "/hls/#{session.session_id}/playlist.m3u8"
    }
  rescue ResolvedSource::Invalid
    render json: { error: "Invalid stream source" }, status: :bad_request
  rescue Media::Transcoder::TranscodeError => e
    Rails.logger.error("[HLS] Failed to start: #{e.message}")
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /hls/:id/playlist.m3u8
  # No cookie auth — iOS Safari's <video> element fetches media without
  # sending session cookies.  The session ID is an unguessable bearer
  # token that authorises the request.
  def playlist
    session = HlsSessionManager.find(params[:id])
    unless session
      head :not_found
      return
    end

    if session.error_message.present?
      render json: { error: session.error_message }, status: :failed_dependency
      return
    end

    # Playlist not ready yet — either the file doesn't exist, or
    # ffmpeg has written the #EXTM3U header but no segment entries
    # yet (the first segment isn't complete).  Return 202 so the
    # client keeps polling.
    unless session.playlist_ready?
      head :accepted
      return
    end

    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    # The session ID in the URL path is an unguessable bearer token.
    # Prevent it leaking to third-party hosts via a Referer header if
    # the player page has external links.
    response.headers["Referrer-Policy"] = "no-referrer"
    send_data File.read(session.playlist_path),
              type: "application/vnd.apple.mpegurl",
              disposition: :inline
  end

  # GET /hls/:id/:segment (e.g. 0.ts, 1.ts)
  #
  # iOS Safari's native HLS player requests segments by index as it
  # plays through the playlist.  When ffmpeg is transcoding slower
  # than 1×, Safari may request a segment that hasn't been written to
  # disk yet.  Returning 404 causes Safari to treat it as a fatal
  # error — playback stops and the screen goes black.  Instead, we
  # block for up to SEGMENT_WAIT_SECONDS for the segment to appear,
  # so Safari's request simply waits until ffmpeg produces it.
  def segment
    session = HlsSessionManager.find(params[:id])
    unless session
      head :not_found
      return
    end
    segment_index = params[:segment].to_i

    availability = HlsSegmentAvailabilityService.new(
      session,
      session_id: params[:id]
    ).call(segment_index)

    case availability.status
    when :failed
      render json: { error: availability.error }, status: :failed_dependency
      return
    when :finished
      head :not_found
      return
    when :pending
      response.headers["Retry-After"] = "1"
      head :service_unavailable
      return
    end

    path = availability.path

    session.prune_consumed_segments(segment_index)
    response.headers["Cache-Control"] = "no-cache"
    response.headers["Referrer-Policy"] = "no-referrer"
    send_file path, type: "video/mp2t", disposition: :inline
  end

  # POST /hls/:id/stop
  def stop
    HlsSessionManager.stop(params[:id])
    head :ok
  end
end
