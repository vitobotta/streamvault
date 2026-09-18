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
      redirect_to streaming_path("play", playback: result.data.to_token(user: current_user))
    else
      redirect_back fallback_location: root_path, alert: result.error_message
    end
  end
  def show
    descriptor = PlaybackDescriptor.resolve(token: params[:playback], user: current_user)
    content_ref = descriptor.content_ref

    @source_token = descriptor.source_token
    @filename = descriptor.filename
    @imdb_id = content_ref.imdb_id
    @type = content_ref.type
    @season = content_ref.season
    @episode = content_ref.episode
    @title = descriptor.title || "Now Playing"
    @poster_url = descriptor.poster_url
    @resume_at = descriptor.resume_at
    @duration = descriptor.duration
    @default_language = current_user.default_stream_language
    @preferred_languages = current_user.preferred_stream_languages
    @direct_play_hint = descriptor.direct_play_hint
    @next_episode_prompt_seconds = (Integer(ENV.fetch("NEXT_EPISODE_PROMPT_SECONDS", "90"), exception: false) || 90).clamp(0, 600)

    @direct_stream_url = direct_stream_path(source: @source_token)
    transcode_params = { source: @source_token }
    transcode_params[:start_seconds] = @resume_at if @resume_at.positive?
    @streaming_url = transcode_stream_path(transcode_params)
  rescue ApplicationToken::Invalid
    redirect_to root_path, alert: "Playback link is invalid or expired."
  end

  # GET /streaming/resume — resolve which episode/movie to play and where to
  # start, then redirect to the player page. Single entry point used by home
  # "Continue Watching" cards and the player's auto-advance.
  def resume
    if params[:after].present?
      descriptor = PlaybackDescriptor.resolve(token: params[:after], user: current_user)
      return head :bad_request unless descriptor.content_ref.show?

      next_episode = Playback::EpisodeSequence.new.next_after(descriptor.content_ref)
      unless next_episode.success?
        return head :no_content if [ :series_complete, :not_released ].include?(next_episode.error_code)

        redirect_to streaming_path("play", playback: params[:after]), alert: next_episode.error_message
        return
      end

      target = {
        season: next_episode.data.season, episode: next_episode.data.episode,
        resume_at: 0, duration_seconds: 0, title: descriptor.title, poster_url: descriptor.poster_url
      }
      start_resume(descriptor.content_ref.imdb_id, "show", target)
      return
    end

    type = params[:type].presence || "show"

    imdb_id = params[:imdb_id]
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

    start_resume(imdb_id, type, target)
  rescue ApplicationToken::Invalid
    redirect_to root_path, alert: "Playback link is invalid or expired."
  end

  # Background lookup: never resolve a stream or delay the current player's startup.
  def next_episode
    descriptor = PlaybackDescriptor.resolve(token: params[:playback], user: current_user)
    return render json: { available: false } unless descriptor.content_ref.show?

    result = Playback::EpisodeSequence.new.next_after(descriptor.content_ref)
    if result.success?
      render json: {
        available: true, season: result.data.season, episode: result.data.episode,
        url: resume_streaming_index_path(after: params[:playback], autoplay: "1")
      }
    elsif [ :series_complete, :not_released ].include?(result.error_code)
      render json: { available: false }
    else
      render json: { available: false }, status: :service_unavailable
    end
  rescue ApplicationToken::Invalid
    render json: { available: false }, status: :bad_request
  end

  # PATCH /streaming/:id/progress — save watch progress
  def progress
    content_ref = ContentRef.new(
      imdb_id: params[:imdb_id],
      type: params[:type] || "movie",
      season: params[:season],
      episode: params[:episode]
    )
    result = Playback::ProgressWriter.new(current_user).call(
      content_ref: content_ref,
      progress_seconds: params[:progress_seconds],
      duration_seconds: params[:duration_seconds],
      title: params[:title],
      poster_url: params[:poster_url]
    )
    if result.success?
      render json: { success: true }
    else
      render json: { error: result.error_message }, status: :unprocessable_entity
    end
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  # POST /streaming/stall_telemetry — structured, credential-free
  # diagnostics correlated by a client-generated playback ID.
  def stall_telemetry
    PlaybackTelemetryService.new.record(user_id: current_user.id, attributes: params)
    render json: { recorded: true }
  end

  private

  def start_resume(imdb_id, type, target)
    result = PlaybackStartService.new(current_user).resume(imdb_id: imdb_id, type: type, target: target)
    if result.success?
      redirect_to streaming_path("play", playback: result.data.to_token(user: current_user))
    else
      redirect_back fallback_location: root_path, alert: result.error_message
    end
  end

  def verify_realdebrid_key!
    unless current_user.has_realdebrid_key?
      redirect_to settings_path, alert: "RealDebrid API key not configured. Please add it in Settings."
    end
  end
end
