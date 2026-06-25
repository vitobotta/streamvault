# frozen_string_literal: true

class StreamingController < ApplicationController
  MIN_KNOWN_DURATION_SECONDS = 60
  MAX_KNOWN_DURATION_SECONDS = 24 * 60 * 60

  before_action :authenticate_user!
  before_action :verify_realdebrid_key!, except: [ :progress ]

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
      progress_entry = find_progress_entry(params[:imdb_id], params[:type], params[:season], params[:episode])
      resume_at = progress_entry&.progress_seconds
      duration = find_duration_seconds(progress_entry, params[:imdb_id], params[:type], params[:season], params[:episode])

      redirect_to streaming_path(
        "play",
        streaming_url: result.data[:streaming_url],
        filename: result.data[:filename],
        imdb_id: params[:imdb_id],
        type: params[:type],
        season: params[:season],
        episode: params[:episode],
        title: params[:title],
        poster_url: params[:poster_url],
        resume_at: resume_at,
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
    @poster_url = params[:poster_url]
    @resume_at = params[:resume_at]
    @duration = normalized_duration_seconds(params[:duration])
    @default_language = current_user.default_stream_language
    @preferred_languages = current_user.preferred_stream_languages

    if @duration.zero?
      progress_entry = find_progress_entry(@imdb_id, @type, @season, @episode)
      @duration = normalized_duration_seconds(progress_entry&.duration_seconds)
      @duration = metadata_duration_seconds(@imdb_id, @type, @season, @episode) if @duration.zero? && params.key?(:duration)
    end

    # Build the FFmpeg proxy URL. Pass resume_at as start_seconds so
    # ffmpeg seeks to the right position (-ss) — the stream starts at
    # the resume point and the browser never needs to seek (which
    # would cancel and re-request).
    if @streaming_url.present?
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

    target = resume_target(imdb_id, type)
    target_season = target[:season]
    target_episode = target[:episode]
    resume_at = target[:resume_at]

    service = ContentStreamingService.new(current_user)
    result = service.start_stream(
      imdb_id,
      type,
      season: target_season,
      episode: target_episode
    )

    if result.success?
      metadata = fetch_show_metadata(imdb_id, type)
      redirect_to streaming_path(
        "play",
        streaming_url: result.data[:streaming_url],
        filename: result.data[:filename],
        imdb_id: imdb_id,
        type: type,
        season: target_season,
        episode: target_episode,
        title: metadata[:title],
        poster_url: metadata[:poster_url],
        resume_at: resume_at,
        duration: 0
      )
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

  private

  def verify_realdebrid_key!
    unless current_user.has_realdebrid_key?
      redirect_to settings_path, alert: "RealDebrid API key not configured. Please add it in Settings."
    end
  end

  def find_progress_entry(imdb_id, type, season, episode)
    if type == "show" && season.present? && episode.present?
      return current_user.episode_progresses.find_by(
        show_imdb_id: imdb_id,
        season_number: season.to_i,
        episode_number: episode.to_i
      )
    end

    current_user.watch_history_entries
      .where(imdb_id: imdb_id)
      .order(watched_at: :desc)
      .first
  end

  # Resolve which episode/movie to play and where to start.
  # Returns { season:, episode:, resume_at: } (season/episode are 0 for movies).
  def resume_target(imdb_id, type)
    if type == "movie"
      last = current_user.watch_history_entries.where(imdb_id: imdb_id).order(watched_at: :desc).first
      return { season: 0, episode: 0, resume_at: 0 } if last.nil?
      return { season: 0, episode: 0, resume_at: 0 } if last.progress_percentage >= 95
      return { season: 0, episode: 0, resume_at: last.progress_seconds }
    end

    last = current_user.episode_progresses.for_show(imdb_id).recently_watched.first
    return { season: 1, episode: 1, resume_at: 0 } if last.nil?

    if last.progress_percentage >= 95
      next_ep = ProgressTrackingService.next_episode(current_user, imdb_id, last.season_number, last.episode_number)
      if next_ep.success?
        { season: next_ep.data[:season], episode: next_ep.data[:episode], resume_at: 0 }
      else
        # Series finale: replay the finished episode from the start
        { season: last.season_number, episode: last.episode_number, resume_at: 0 }
      end
    else
      { season: last.season_number, episode: last.episode_number, resume_at: last.progress_seconds }
    end
  end

  def fetch_show_metadata(imdb_id, type)
    meta_result = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key).metadata(imdb_id, type)
    return { title: nil, poster_url: nil } if meta_result.failure?
    { title: meta_result.data[:title], poster_url: meta_result.data[:poster_url] }
  rescue StandardError
    { title: nil, poster_url: nil }
  end

  def find_duration_seconds(progress_entry, imdb_id, type, season, episode)
    saved_duration = normalized_duration_seconds(progress_entry&.duration_seconds)
    return saved_duration if saved_duration.positive?

    requested_duration = request_duration_seconds
    return requested_duration if requested_duration.positive?

    metadata_duration_seconds(imdb_id, type, season, episode)
  end

  def request_duration_seconds
    duration = params[:duration].presence || params[:duration_seconds].presence
    normalized_duration_seconds(duration)
  end

  def metadata_duration_seconds(imdb_id, type, season, episode)
    meta_result = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key).metadata(imdb_id, type)
    return 0 if meta_result.failure?

    if type == "show" && season.present? && episode.present?
      selected_episode = meta_result.data[:episodes]&.find do |ep|
        ep[:season].to_i == season.to_i && ep[:episode].to_i == episode.to_i
      end
      return normalized_duration_seconds(selected_episode&.dig(:runtime_seconds))
    end

    normalized_duration_seconds(meta_result.data[:runtime_seconds])
  rescue StandardError => e
    Rails.logger.warn("[Streaming] duration metadata lookup failed: #{e.message}")
    0
  end

  def normalized_duration_seconds(value)
    seconds = value.to_i
    return seconds if seconds >= MIN_KNOWN_DURATION_SECONDS && seconds <= MAX_KNOWN_DURATION_SECONDS

    0
  end
end
