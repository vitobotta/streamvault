# frozen_string_literal: true

class PlaybackStartService
  MIN_KNOWN_DURATION_SECONDS = 60
  MAX_KNOWN_DURATION_SECONDS = 24 * 60 * 60

  def initialize(user, streaming_service: ContentStreamingService.new(user), logger: Rails.logger)
    @user = user
    @streaming_service = streaming_service
    @logger = logger
  end

  def start(imdb_id:, type:, season: nil, episode: nil, title: nil, poster_url: nil, requested_duration: nil, selection: {})
    stream_result = resolve_stream(imdb_id, type, season, episode, selection)
    return stream_result if stream_result.failure?

    progress_entry = find_progress_entry(imdb_id, type, season, episode)
    duration = duration_for(
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode,
      progress_entry: progress_entry,
      requested_duration: requested_duration
    )

    ServiceResult.success(
      playback_payload(
        stream: stream_result.data,
        imdb_id: imdb_id,
        type: type,
        season: season,
        episode: episode,
        title: title,
        poster_url: poster_url,
        resume_at: progress_entry&.progress_seconds,
        duration: duration
      )
    )
  end

  def resume(imdb_id:, type:, target:)
    stream_result = @streaming_service.start_stream(
      imdb_id,
      type,
      season: target[:season],
      episode: target[:episode]
    )
    return stream_result if stream_result.failure?

    ServiceResult.success(
      playback_payload(
        stream: stream_result.data,
        imdb_id: imdb_id,
        type: type,
        season: target[:season],
        episode: target[:episode],
        title: target[:title],
        poster_url: target[:poster_url],
        resume_at: target[:resume_at],
        duration: target[:duration_seconds]
      )
    )
  end

  def known_duration(imdb_id:, type:, season: nil, episode: nil, requested_duration: nil, metadata_fallback: true)
    requested = normalized_duration_seconds(requested_duration)
    return requested if requested.positive?

    progress_entry = find_progress_entry(imdb_id, type, season, episode)
    saved = normalized_duration_seconds(progress_entry&.duration_seconds)
    return saved if saved.positive?
    return 0 unless metadata_fallback

    metadata_duration_seconds(imdb_id, type, season, episode)
  end

  private

  def resolve_stream(imdb_id, type, season, episode, selection)
    if selection[:resolve_url].present?
      @streaming_service.resolve_single(
        selection[:resolve_url],
        filename: selection[:filename],
        imdb_id: imdb_id,
        type: type,
        season: season&.to_i,
        episode: episode&.to_i,
        duration: selection[:duration],
        raw_size: selection[:raw_size],
        video_codec: selection[:video_codec],
        compatibility_score: selection[:compatibility_score]
      )
    else
      @streaming_service.start_stream(
        imdb_id,
        type,
        season: season&.to_i,
        episode: episode&.to_i
      )
    end
  end

  def playback_payload(stream:, imdb_id:, type:, season:, episode:, title:, poster_url:, resume_at:, duration:)
    payload = {
      streaming_url: stream[:streaming_url],
      filename: stream[:filename],
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode,
      title: title,
      poster_url: poster_url,
      resume_at: resume_at,
      duration: normalized_duration_seconds(duration)
    }
    payload[:direct_play_hint] = true if stream[:direct_play_hint]
    payload
  end

  def find_progress_entry(imdb_id, type, season, episode)
    if type == "show" && season.present? && episode.present?
      return @user.episode_progresses.find_by(
        show_imdb_id: imdb_id,
        season_number: season.to_i,
        episode_number: episode.to_i
      )
    end

    @user.watch_history_entries.where(imdb_id: imdb_id).order(watched_at: :desc).first
  end

  def duration_for(imdb_id:, type:, season:, episode:, progress_entry:, requested_duration:)
    saved_duration = normalized_duration_seconds(progress_entry&.duration_seconds)
    return saved_duration if saved_duration.positive?

    requested = normalized_duration_seconds(requested_duration)
    return requested if requested.positive?

    metadata_duration_seconds(imdb_id, type, season, episode)
  end

  def metadata_duration_seconds(imdb_id, type, season, episode)
    result = TorrentioService.new(rd_api_key: @user.realdebrid_api_key).metadata(imdb_id, type)
    return 0 if result.failure?

    if type == "show" && season.present? && episode.present?
      selected_episode = result.data[:episodes]&.find do |candidate|
        candidate[:season].to_i == season.to_i && candidate[:episode].to_i == episode.to_i
      end
      return normalized_duration_seconds(selected_episode&.dig(:runtime_seconds))
    end

    normalized_duration_seconds(result.data[:runtime_seconds])
  rescue StandardError => e
    @logger.warn("[PlaybackStartService] duration metadata lookup failed: #{e.message}")
    0
  end

  def normalized_duration_seconds(value)
    seconds = value.to_i
    return seconds if seconds.between?(MIN_KNOWN_DURATION_SECONDS, MAX_KNOWN_DURATION_SECONDS)

    0
  end
end
