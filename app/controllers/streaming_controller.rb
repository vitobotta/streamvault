# frozen_string_literal: true

class StreamingController < ApplicationController
  before_action :authenticate_user!
  before_action :verify_realdebrid_key!, except: [:progress]

  def create
    service = ContentStreamingService.new(current_user)
    result = service.start_stream(
      params[:imdb_id],
      params[:type],
      season: params[:season]&.to_i,
      episode: params[:episode]&.to_i
    )

    if result.success?
      render json: result.data
    else
      render json: { error: result.error_message }, status: :unprocessable_entity
    end
  end

  def show
    service = ContentStreamingService.new(current_user)
    result = service.get_streaming_url(params[:id], params[:file_idx])

    if result.success?
      render json: result.data
    else
      render json: { error: result.error_message }, status: :unprocessable_entity
    end
  end

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
      render json: { error: "RealDebrid API key not configured. Please add it in Settings." }, status: :forbidden
    end
  end
end
