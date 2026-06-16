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
      redirect_to streaming_path(
        "play",
        streaming_url: result.data[:streaming_url],
        filename: result.data[:filename],
        imdb_id: params[:imdb_id],
        type: params[:type],
        season: params[:season],
        episode: params[:episode],
        title: params[:title]
      )
    else
      redirect_back fallback_location: root_path, alert: result.error_message
    end
  end

  # GET /streaming/:id — player page (streaming_url already resolved)
  def show
    @streaming_url = params[:streaming_url]
    @filename = params[:filename]
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]
    @episode = params[:episode]
    @title = params[:title] || "Now Playing"
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
