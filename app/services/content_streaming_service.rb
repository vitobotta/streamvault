# frozen_string_literal: true

class ContentStreamingService
  MAX_STREAM_ATTEMPTS = 50
  RESOLVE_BATCH_SIZE = 10
  RESOLVE_RETRIES = 1

  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new(rd_api_key: user.realdebrid_api_key)
  end

  def start_stream(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    streams_result = fetch_streams(imdb_id, type, season: season, episode: episode)
    return streams_result if streams_result.failure?

    streams = streams_result.data
    return ServiceResult.failure("No streams available for this content") if streams.empty?

    candidates = stream_candidates(streams)
    result = resolve_first_valid(candidates)

    if result
      stream_result(result, imdb_id: imdb_id, type: type, season: season, episode: episode)
    else
      ServiceResult.failure("No instant streams available. All streams are blocked or unavailable.")
    end
  end

  # Resolve a specific stream chosen by the user (via resolve_url).
  # The chosen stream is tried first so a Direct Play MP4 still wins over
  # a fallback MKV, but stale/blocked Torrentio links are common enough
  # that we retry the current candidate list before failing the request.
  def resolve_single(resolve_url, filename:, imdb_id:, type:, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    selected_stream = { resolve_url: resolve_url, filename: filename }
    result = resolve_stream(selected_stream) || resolve_fallback_streams(resolve_url, imdb_id, type, season: season, episode: episode)

    if result
      stream_result(result, imdb_id: imdb_id, type: type, season: season, episode: episode)
    else
      ServiceResult.failure("Could not resolve the selected stream. It may be blocked or unavailable.")
    end
  end

  private

  BLOCKED_PATTERNS = /downloading|infringing|failed.infringement|removed|blocked/i

  def fetch_streams(imdb_id, type, season: nil, episode: nil)
    meta = @torrentio.metadata(imdb_id, type)
    content_title = meta.success? ? meta.data[:title] : nil

    @torrentio.streams(
      imdb_id,
      type,
      season: season,
      episode: episode,
      title: content_title,
      preferred_languages: @user.preferred_stream_languages
    )
  end

  def stream_candidates(streams)
    streams.first(MAX_STREAM_ATTEMPTS).select { |s| s[:resolve_url].present? }
  end

  def resolve_stream(stream)
    resolved = verify_resolve_url(stream[:resolve_url])
    return unless resolved

    { **resolved, stream: stream }
  end

  def resolve_fallback_streams(selected_resolve_url, imdb_id, type, season:, episode:)
    streams_result = fetch_streams(imdb_id, type, season: season, episode: episode)
    return if streams_result.failure?

    candidates = stream_candidates(streams_result.data)
      .reject { |stream| stream[:resolve_url] == selected_resolve_url }

    resolve_first_valid(candidates)
  end

  def stream_result(result, imdb_id:, type:, season:, episode:)
    torrent_filename = result[:stream][:filename].presence || result[:filename]

    ServiceResult.success({
      streaming_url: result[:streaming_url],
      filename: torrent_filename,
      stream: result[:stream].merge(filename: torrent_filename),
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode
    })
  end

  def resolve_first_valid(candidates)
    candidates.each_slice(RESOLVE_BATCH_SIZE) do |batch|
      winner = resolve_first_valid_batch(batch)
      return winner if winner
    end

    nil
  end

  def resolve_first_valid_batch(candidates)
    mutex = Mutex.new
    winner = nil

    threads = candidates.map do |stream|
      Thread.new(stream) do |s|
        already_done = mutex.synchronize { !!winner }
        next if already_done

        resolved = resolve_stream(s)
        mutex.synchronize { winner ||= resolved } if resolved
      end
    end

    threads.each(&:join)
    winner
  end

  def verify_resolve_url(resolve_url)
    return nil unless allowed_resolve_url?(resolve_url)

    response = with_resolve_retries { resolve_faraday.get(resolve_url) }
    return nil unless response

    if [ 301, 302, 303, 307, 308 ].include?(response.status)
      location = response.headers["location"]
      return nil if location.blank?
      return nil if location.match?(BLOCKED_PATTERNS)
      return nil unless http_url?(location)
      filename = location.split("/").last.to_s
      return nil if filename.match?(BLOCKED_PATTERNS)
      { streaming_url: location, filename: filename }
    elsif [ 200, 206 ].include?(response.status)
      filename = resolve_url.split("/").last.to_s
      return nil if filename.match?(BLOCKED_PATTERNS)
      { streaming_url: resolve_url, filename: filename }
    else
      nil
    end
  end

  def with_resolve_retries
    attempts = 0

    begin
      attempts += 1
      yield
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed
      retry if attempts <= RESOLVE_RETRIES
      nil
    end
  end

  def allowed_resolve_url?(resolve_url)
    uri = URI.parse(resolve_url.to_s)
    return false unless uri.is_a?(URI::HTTP)

    allowed_resolve_origins.any? do |origin|
      uri.scheme == origin.scheme && uri.host == origin.host && uri.port == origin.port
    end
  rescue URI::InvalidURIError
    false
  end

  def allowed_resolve_origins
    @allowed_resolve_origins ||= [
      "https://torrentio.strem.fun",
      TorrentioService::TORRENTIO_URL
    ].filter_map do |url|
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end.uniq { |uri| [ uri.scheme, uri.host, uri.port ] }
  end

  def http_url?(url)
    URI.parse(url.to_s).is_a?(URI::HTTP)
  rescue URI::InvalidURIError
    false
  end

  def resolve_faraday
    @resolve_faraday ||= begin
      proxy = ENV["TORRENTIO_PROXY"]
      Faraday.new do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
        f.proxy = proxy if proxy.present?
      end
    end
  end
end
