# frozen_string_literal: true

class StreamingController < ApplicationController
  include ContentParamValidation

  layout "player"
  before_action :authenticate_user!
  # stall_telemetry is a diagnostic endpoint — it should work even if
  # the user hasn't configured an RD key yet (so we can see stalls from
  # the player regardless of auth state).  progress is excluded because
  # it's a fire-and-forget save that doesn't need the key.
  before_action :verify_realdebrid_key!, except: [ :progress, :stall_telemetry ]

  # POST /streaming — start stream, redirect to player page
  def create
    imdb_id = params[:imdb_id]
    type = params[:type]
    return if reject_invalid_imdb_id!(imdb_id) || reject_invalid_content_type!(type)

    result = PlaybackStartService.new(current_user).start(
      imdb_id: imdb_id,
      type: type,
      season: params[:season],
      episode: params[:episode],
      title: params[:title],
      poster_url: params[:poster_url],
      requested_duration: params[:duration].presence || params[:duration_seconds].presence,
      selection: {
        resolve_url: params[:resolve_url],
        filename: params[:filename],
        duration: params[:duration],
        raw_size: params[:raw_size],
        video_codec: params[:video_codec],
        compatibility_score: params[:compatibility_score]
      }
    )

    if result.success?
      redirect_to streaming_path("play", result.data)
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
    @poster_url = params[:poster_url]
    @resume_at = params[:resume_at]
    @duration = PlaybackStartService.new(current_user).known_duration(
      imdb_id: @imdb_id,
      type: @type,
      season: @season,
      episode: @episode,
      requested_duration: params[:duration],
      metadata_fallback: params.key?(:duration)
    )
    @default_language = current_user.default_stream_language
    @preferred_languages = current_user.preferred_stream_languages
    @direct_play_hint = ActiveModel::Type::Boolean.new.cast(params[:direct_play_hint]) == true

    # Build the FFmpeg proxy URL. Pass resume_at as start_seconds so
    # ffmpeg seeks to the right position (-ss) — the stream starts at
    # the resume point and the browser never needs to seek (which
    # would cancel and re-request).
    # Preserve the original RealDebrid URL for the iOS HLS path and direct
    # play before overwriting @streaming_url with the transcode proxy URL.
    @direct_url = @streaming_url
    if @streaming_url.present?
      # Build the direct stream proxy URL so the browser downloads at
      # network speed — no ffmpeg involved for compatible content.
      @direct_stream_url = direct_stream_path(url: @direct_url)

      transcode_params = { url: @streaming_url }
      transcode_params[:start_seconds] = @resume_at if @resume_at.present? && @resume_at.to_f > 0
      transcode_params[:audio_stream] = params[:audio_stream] if params[:audio_stream].present?
      transcode_params[:subtitle_stream] = params[:subtitle_stream] if params[:subtitle_stream].present?
      @streaming_url = transcode_stream_path(transcode_params)
    end
  end

  # GET /streaming/resume — resolve which episode/movie to play and where to
  # start, then redirect to the player page. Single entry point used by home
  # "Continue Watching" cards and the player's auto-advance.
  def resume
    type = params[:type].presence || "show"

    imdb_id = type == "show" ? params[:show_imdb_id] : params[:imdb_id]
    if imdb_id.blank?
      redirect_back fallback_location: root_path, alert: (type == "show" ? "Show not found" : "Content not found")
      return
    end

    target_result = PlaybackResumeService.new(current_user).call(imdb_id: imdb_id, type: type)
    unless target_result.success?
      redirect_back fallback_location: root_path, alert: target_result.error_message
      return
    end
    target = target_result.data
    if target[:series_complete] && ActiveModel::Type::Boolean.new.cast(params[:autoplay])
      head :no_content
      return
    end

    result = PlaybackStartService.new(current_user).resume(
      imdb_id: imdb_id,
      type: type,
      target: target
    )

    if result.success?
      redirect_to streaming_path("play", result.data)
    else
      redirect_back fallback_location: root_path, alert: result.error_message
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
      title: params[:title],
      poster_url: params[:poster_url]
    )

    if result.success?
      render json: { success: true }
    else
      render json: { error: result.error_message }, status: :unprocessable_entity
    end
  end

  # POST /streaming/stall_telemetry — structured, credential-free
  # diagnostics correlated by a client-generated playback ID.
  def stall_telemetry
    PlaybackTelemetryService.new.record(user_id: current_user.id, attributes: params)
    render json: { recorded: true }
  end

  private

  def verify_realdebrid_key!
    unless current_user.has_realdebrid_key?
      redirect_to settings_path, alert: "RealDebrid API key not configured. Please add it in Settings."
    end
  end
end
