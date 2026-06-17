# frozen_string_literal: true

class StreamingController < ApplicationController
  before_action :authenticate_user!
  before_action :verify_realdebrid_key!, except: [:progress]

  # POST /streaming — start stream, redirect to player page
  def create
    service = ContentStreamingService.new(current_user)

    # When the user clicks a specific stream's "Watch" button, we
    # receive its resolve_url and filename. Resolve that exact stream
    # instead of re-fetching all streams and racing — the user chose
    # this stream, respect the choice (e.g. a Direct Play MP4).
    if params[:resolve_url].present?
      result = service.resolve_single(
        params[:resolve_url],
        filename: params[:filename],
        imdb_id: params[:imdb_id],
        type: params[:type],
        season: params[:season]&.to_i,
        episode: params[:episode]&.to_i
      )
    else
      result = service.start_stream(
        params[:imdb_id],
        params[:type],
        season: params[:season]&.to_i,
        episode: params[:episode]&.to_i
      )
    end

    if result.success?
      resume_at = find_resume_position(params[:imdb_id], params[:type], params[:season], params[:episode])

      redirect_to streaming_path(
        "play",
        streaming_url: result.data[:streaming_url],
        filename: result.data[:filename],
        imdb_id: params[:imdb_id],
        type: params[:type],
        season: params[:season],
        episode: params[:episode],
        title: params[:title],
        resume_at: resume_at,
        duration: 0
      )
    else
      redirect_back fallback_location: root_path, alert: result.error_message
    end
  end
  def show
    @streaming_url = params[:streaming_url]
    @filename = params[:filename]
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]
    @episode = params[:episode]
    @title = params[:title] || "Now Playing"
    @resume_at = params[:resume_at]
    @duration = params[:duration].to_f

    # Build the FFmpeg proxy URL. Pass resume_at as start_seconds so
    # ffmpeg seeks to the right position (-ss) — the stream starts at
    # the resume point and the browser never needs to seek (which
    # would cancel and re-request).
    if @streaming_url.present?
      transcode_params = { url: @streaming_url }
      transcode_params[:start_seconds] = @resume_at if @resume_at.present? && @resume_at.to_f > 0
      @streaming_url = transcode_stream_path(transcode_params)
    end
  end

  # PATCH /streaming/:id/progress — save watch progress
  def progress
    result = ProgressTrackingService.save_progress(
      current_user,
      params[:imdb_id],
      params[:progress_seconds].to_i,
      params[:duration_seconds].to_i,
      type: params[:type] || "movie",
      season: params[:season]&.to_i,
      episode: params[:episode]&.to_i,
      title: params[:title]
    )

    if result.success?
      render json: { success: true }
    else
      render json: { error: result.error_message }, status: :unprocessable_entity
    end
  end

  private

  def verify_realdebrid_key!
    unless current_user.has_realdebrid_key?
      redirect_to settings_path, alert: "RealDebrid API key not configured. Please add it in Settings."
    end
  end

  def find_resume_position(imdb_id, type, season, episode)
    if type == "show" && season.present? && episode.present?
      ep = current_user.episode_progresses.find_by(
        show_imdb_id: imdb_id,
        season_number: season.to_i,
        episode_number: episode.to_i
      )
      return ep&.progress_seconds
    end

    entry = current_user.watch_history_entries
      .where(imdb_id: imdb_id)
      .order(watched_at: :desc)
      .first
    entry&.progress_seconds
  end
end
