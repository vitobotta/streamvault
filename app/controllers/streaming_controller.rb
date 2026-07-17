# frozen_string_literal: true

class StreamingController < ApplicationController
  include ContentParamValidation

  layout "player"
  MIN_KNOWN_DURATION_SECONDS = 60
  MAX_KNOWN_DURATION_SECONDS = 24 * 60 * 60

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

    service = ContentStreamingService.new(current_user)

    # When the user clicks a specific stream's "Watch" button, we
    # receive its resolve_url and filename. Resolve that exact stream
    # instead of re-fetching all streams and racing — the user chose
    # this stream, respect the choice (e.g. a Direct Play MP4).
    if params[:resolve_url].present?
      result = service.resolve_single(
        params[:resolve_url],
        filename: params[:filename],
        imdb_id: imdb_id,
        type: type,
        season: params[:season]&.to_i,
        episode: params[:episode]&.to_i,
        duration: params[:duration],
        raw_size: params[:raw_size],
        video_codec: params[:video_codec]
      )
    else
      result = service.start_stream(
        imdb_id,
        type,
        season: params[:season]&.to_i,
        episode: params[:episode]&.to_i
      )
    end

    if result.success?
      progress_entry = find_progress_entry(imdb_id, type, params[:season], params[:episode])
      resume_at = progress_entry&.progress_seconds
      duration = find_duration_seconds(progress_entry, imdb_id, type, params[:season], params[:episode])

      redirect_to streaming_path(
        "play",
        streaming_url: result.data[:streaming_url],
        filename: result.data[:filename],
        imdb_id: imdb_id,
        type: type,
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
      # Metadata (title, poster_url, duration) comes from the DB
      # progress row loaded by resume_target — no Cinemeta round-trip
      # needed. This eliminates a 1-10s HTTP call on every resume.
      redirect_to streaming_path(
        "play",
        streaming_url: result.data[:streaming_url],
        filename: result.data[:filename],
        imdb_id: imdb_id,
        type: type,
        season: target_season,
        episode: target_episode,
        title: target[:title],
        poster_url: target[:poster_url],
        resume_at: resume_at,
        duration: target[:duration_seconds].to_i
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

  # POST /streaming/stall_telemetry — structured, credential-free
  # diagnostics correlated by a client-generated playback ID.
  def stall_telemetry
    payload = {
      event: sanitize_log_value(params[:event], 48),
      playback_id: sanitize_log_value(params[:playback_id], 80),
      path: sanitize_log_value(params[:path], 32),
      position: finite_log_number(params[:position]),
      buffer_ahead: finite_log_number(params[:buffer_ahead]),
      recovery_count: bounded_log_integer(params[:recovery_count], 0, 100),
      ready_state: bounded_log_integer(params[:ready_state], 0, 4),
      network_state: bounded_log_integer(params[:network_state], 0, 3),
      paused: ActiveModel::Type::Boolean.new.cast(params[:paused]),
      ended: ActiveModel::Type::Boolean.new.cast(params[:ended]),
      mse_pending_bytes: bounded_log_integer(params[:mse_pending_bytes], 0, 1.gigabyte),
      mse_quota_errors: bounded_log_integer(params[:mse_quota_errors], 0, 10_000),
      system_rebuffer_paused: ActiveModel::Type::Boolean.new.cast(params[:system_rebuffer_paused]),
      buffered_ranges: sanitized_buffered_ranges(params[:buffered_ranges]),
      video_codec: sanitize_log_value(params[:video_codec], 24),
      video_width: bounded_log_integer(params[:video_width], 0, 16_384),
      video_height: bounded_log_integer(params[:video_height], 0, 16_384),
      start_seconds: finite_log_number(params[:start_seconds]),
      user_id: current_user.id
    }

    Rails.logger.info("[StallTelemetry] #{payload.to_json}")
    render json: { recorded: true }
  end

  private

  def verify_realdebrid_key!
    unless current_user.has_realdebrid_key?
      redirect_to settings_path, alert: "RealDebrid API key not configured. Please add it in Settings."
    end
  end

  # Strip CR/LF/tab from log values to prevent log injection (forging
  # fake log lines that a naive log consumer might ingest as real).
  def sanitize_log_value(value, max_length = 128)
    value.to_s.gsub(/[\r\n\t]/, " ").first(max_length)
  end

  def finite_log_number(value)
    number = Float(value, exception: false)
    number&.finite? ? number.round(2) : 0
  end

  def bounded_log_integer(value, minimum, maximum)
    value.to_i.clamp(minimum, maximum)
  end

  def sanitized_buffered_ranges(value)
    Array(value).first(8).filter_map do |range|
      next unless range.is_a?(Array) && range.length >= 2

      [ finite_log_number(range[0]), finite_log_number(range[1]) ]
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

  # Resolve which episode/movie to play, where to start, and metadata
 # (title, poster_url, duration) from the existing DB progress row.
 # Returns { season:, episode:, resume_at:, title:, poster_url:, duration_seconds: }.
 #
 # For shows resuming an in-progress episode, the episode_progresses row
 # holds show_title and duration_seconds. For movies, the watch_history_entries
 # row holds title, poster_url, and duration_seconds.
 #
 # When advancing to a next episode (progress >= 95%), no DB row exists
 # for the next episode yet — duration falls back to 0 and the player's
 # probeDuration fills it in. When no progress row exists at all (first
 # play), metadata is empty and the player page handles the fallback.
  def resume_target(imdb_id, type)
    if type == "movie"
      last = current_user.watch_history_entries.where(imdb_id: imdb_id).order(watched_at: :desc).first
      return { season: 0, episode: 0, resume_at: 0, title: nil, poster_url: nil, duration_seconds: 0 } if last.nil?
      return { season: 0, episode: 0, resume_at: 0, title: last.title, poster_url: last.poster_url, duration_seconds: last.duration_seconds } if last.progress_percentage >= 95
      return { season: 0, episode: 0, resume_at: last.progress_seconds, title: last.title, poster_url: last.poster_url, duration_seconds: last.duration_seconds }
    end

    last = current_user.episode_progresses.for_show(imdb_id).recently_watched.first
    return { season: 1, episode: 1, resume_at: 0, title: nil, poster_url: nil, duration_seconds: 0 } if last.nil?

    if last.progress_percentage >= 95
      next_ep = ProgressTrackingService.next_episode(current_user, imdb_id, last.season_number, last.episode_number)
      if next_ep.success?
        { season: next_ep.data[:season], episode: next_ep.data[:episode], resume_at: 0, title: last.show_title, poster_url: nil, duration_seconds: 0 }
      else
        # Series finale: replay the finished episode from the start
        { season: last.season_number, episode: last.episode_number, resume_at: 0, title: last.show_title, poster_url: nil, duration_seconds: last.duration_seconds }
      end
    else
      { season: last.season_number, episode: last.episode_number, resume_at: last.progress_seconds, title: last.show_title, poster_url: nil, duration_seconds: last.duration_seconds }
    end
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
