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
        resolve_url: result.data[:resolve_url],
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

  # GET /streaming/:id — player page
  def show
    @resolve_url = params[:resolve_url]
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]
    @episode = params[:episode]
    @title = params[:title] || "Now Playing"
  end

  # GET /streaming/:id/url — resolve the actual streaming URL
  def url
    resolve_url = params[:resolve_url]
    if resolve_url.blank?
      render json: { error: "Missing resolve URL" }, status: :bad_request
      return
    end

    conn = Faraday.new do |f|
      f.adapter Faraday.default_adapter
      f.options.timeout = 15
      f.options.open_timeout = 5
    end

    begin
      response = conn.get(resolve_url) do |req|
        req.options.on_data = Proc.new { } # discard body
      end

      if [301, 302, 303, 307, 308].include?(response.status)
        location = response.headers["location"]
        if location&.include?("downloading")
          render json: { status: "downloading", progress: 0 }
        else
          render json: { status: "ready", streaming_url: location, filename: location&.split("/")&.last }
        end
      elsif response.status == 200
        render json: { status: "ready", streaming_url: resolve_url }
      else
        render json: { status: "waiting", progress: 0 }
      end
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed
      render json: { status: "waiting", progress: 0 }
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
