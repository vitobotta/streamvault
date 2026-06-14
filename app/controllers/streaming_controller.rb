# frozen_string_literal: true

class StreamingController < ApplicationController
  before_action :authenticate_user!
  before_action :verify_realdebrid_key!, except: [:progress]

  # POST /streaming — add magnet, redirect to player
  def create
    service = ContentStreamingService.new(current_user)
    result = service.start_stream(
      params[:imdb_id],
      params[:type],
      season: params[:season]&.to_i,
      episode: params[:episode]&.to_i
    )

    if result.success?
      redirect_to streaming_path(
        result.data[:torrent_id],
        imdb_id: params[:imdb_id],
        type: params[:type],
        season: params[:season],
        episode: params[:episode],
        title: params[:title],
        file_idx: result.data[:file_idx]
      )
    else
      redirect_back fallback_location: root_path, alert: result.error_message
    end
  end

  # GET /streaming/:id — player page
  def show
    @torrent_id = params[:id]
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]
    @episode = params[:episode]
    @title = params[:title] || "Now Playing"
    @file_idx = params[:file_idx]
  end

  # GET /streaming/:id/url — JSON endpoint for polling
  def url
    service = ContentStreamingService.new(current_user)
    result = service.get_streaming_url(params[:id], params[:file_idx])

    if result.success?
      render json: result.data
    else
      render json: { error: result.error_message }, status: :unprocessable_entity
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
      episode: params[:episode]&.to_i
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
end
