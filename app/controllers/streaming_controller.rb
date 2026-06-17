# frozen_string_literal: true

class StreamingController < ApplicationController
  before_action :authenticate_user!
  before_action :verify_realdebrid_key!, except: [:progress]

  # POST /streaming — start stream, redirect to player page
  def create
    service = ContentStreamingService.new(current_user)
    result = service.start_stream(
      params[:imdb_id],
      params[:type],
      season: params[:season]&.to_i,
      episode: params[:episode]&.to_i
    )

    if result.success?
      resume_at = find_resume_position(params[:imdb_id], params[:type], params[:season], params[:episode])
      needs_transcode = TranscodeService.needs_transcode?(result.data[:filename])

      # Probe duration here so the player doesn't need a separate
      # AJAX round-trip to /transcode/duration. The probe is cached
      # so the transcode endpoint reuses it instantly.
      duration = 0
      if needs_transcode
        headers = {}
        if current_user.has_realdebrid_key?
          headers["Authorization"] = "Bearer #{current_user.realdebrid_api_key}"
        end
        duration = TranscodeService.probe_duration(result.data[:streaming_url], headers: headers)
      end

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
        needs_transcode: needs_transcode,
        duration: duration
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
    @needs_transcode = params[:needs_transcode] == "true"
    @duration = params[:duration].to_f

    # If transcode needed, use our FFmpeg proxy URL.
    # Pass resume_at as start_seconds so ffmpeg seeks to the right
    # position (-ss) — the stream starts at the resume point and the
    # browser never needs to seek (which would cancel and re-request).
    if @needs_transcode && @streaming_url.present?
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
