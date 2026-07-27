# frozen_string_literal: true

class PlaybackStartService
  MIN_KNOWN_DURATION_SECONDS = 60
  MAX_KNOWN_DURATION_SECONDS = 24 * 60 * 60

  def initialize(user, streaming_service: Streams::Resolver.new(user), catalog: Catalog::CinemetaClient.new, logger: Rails.logger)
    @user = user
    @streaming_service = streaming_service
    @catalog = catalog
    @logger = logger
  end

  def start(imdb_id:, type:, season: nil, episode: nil, title: nil, poster_url: nil, requested_duration: nil, selection: {})
    content_ref = ContentRef.new(imdb_id: imdb_id, type: type, season: season, episode: episode)
    stream_result = resolve_stream(content_ref, selection)
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
      playback_descriptor(
        stream: stream_result.data,
        content_ref: content_ref,
        title: title,
        poster_url: poster_url,
        resume_at: progress_entry&.progress_seconds,
        duration: duration
      )
    )
  rescue ArgumentError => e
    ServiceResult.failure(e.message)
  end

  def resume(imdb_id:, type:, target:)
    content_ref = ContentRef.new(
      imdb_id: imdb_id,
      type: type,
      season: target[:season],
      episode: target[:episode]
    )
    stream_result = @streaming_service.start(content_ref)
    return stream_result if stream_result.failure?

    ServiceResult.success(
      playback_descriptor(
        stream: stream_result.data,
        content_ref: content_ref,
        title: target[:title],
        poster_url: target[:poster_url],
        resume_at: target[:resume_at],
        duration: target[:duration_seconds]
      )
    )
  rescue ArgumentError => e
    ServiceResult.failure(e.message)
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

  def resolve_stream(content_ref, selection)
    if selection[:resolve_url].present?
      candidate = StreamCandidate.new(
        resolve_url: selection[:resolve_url],
        filename: selection[:filename],
        raw_size: selection[:raw_size],
        video_codec: selection[:video_codec],
        compatibility_score: selection[:compatibility_score]
      )
      @streaming_service.resolve(candidate, content_ref: content_ref, duration: selection[:duration])
    else
      @streaming_service.start(content_ref)
    end
  end

  def playback_descriptor(stream:, content_ref:, title:, poster_url:, resume_at:, duration:)
    source = stream[:source]
    source ||= ResolvedSource.new(url: stream.fetch(:streaming_url), filename: stream[:filename])

    PlaybackDescriptor.new(
      source_token: ResolvedSource.issue(user: @user, url: source.url, filename: source.filename),
      filename: source.filename,
      content_ref: content_ref,
      title: title,
      poster_url: poster_url,
      resume_at: resume_at,
      duration: normalized_duration_seconds(duration),
      direct_play_hint: stream[:direct_play_hint]
    )
  end

  def find_progress_entry(imdb_id, type, season, episode)
    @user.playback_progresses.find_by(
      imdb_id: imdb_id,
      content_type: type == "show" ? :episode : :movie,
      season_number: type == "show" ? season.to_i : 0,
      episode_number: type == "show" ? episode.to_i : 0
    )
  end

  def duration_for(imdb_id:, type:, season:, episode:, progress_entry:, requested_duration:)
    saved_duration = normalized_duration_seconds(progress_entry&.duration_seconds)
    return saved_duration if saved_duration.positive?

    requested = normalized_duration_seconds(requested_duration)
    return requested if requested.positive?

    metadata_duration_seconds(imdb_id, type, season, episode)
  end

  def metadata_duration_seconds(imdb_id, type, season, episode)
    result = @catalog.metadata(imdb_id, type)
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
