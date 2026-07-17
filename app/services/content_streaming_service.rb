# frozen_string_literal: true

class ContentStreamingService
  MAX_STREAM_ATTEMPTS = 50
  RESOLVE_BATCH_SIZE = 10
  RESOLVE_RETRIES = 1
  # Transcoding must read the source faster than real time. Leave enough
  # headroom for CDN variance instead of selecting a file whose average
  # bitrate already consumes the whole upstream connection.
  MAX_TRANSCODE_SOURCE_BITRATE_BPS = 16_000_000
  HEAVY_VIDEO_CODECS = %w[hevc h265 av1 vp9].freeze
  QUALITY_ORDER = { "4K" => 0, "1080p" => 1, "720p" => 2, "480p" => 3, "Unknown" => 4 }.freeze

  def initialize(user)
    @user = user
    @providers = StreamProvider.providers(rd_api_key: user.realdebrid_api_key)
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

  # Resolve a specific stream chosen by the user (via resolve_url). Exact
  # choices are preserved unless a heavy-transcode source has a known average
  # bitrate that the upstream cannot sustain; in that case, prefer a smaller
  # compatible source and fall back to the original when none is available.
  def resolve_single(resolve_url, filename:, imdb_id:, type:, season: nil, episode: nil,
    duration: nil, raw_size: nil, video_codec: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    selected_stream = {
      resolve_url: resolve_url,
      filename: filename,
      raw_size: positive_number(raw_size),
      video_codec: video_codec.to_s.downcase
    }

    used_playback_safe_alternative = false
    result = if oversized_transcode_source?(selected_stream, duration)
      Rails.logger.warn(
        "[ContentStreamingService] Selected transcode source exceeds sustainable bitrate " \
        "for imdb_id=#{imdb_id}; resolving a playback-safe alternative"
      )
      alternative = resolve_playback_safe_alternative(
        resolve_url,
        imdb_id,
        type,
        duration: duration,
        season: season,
        episode: episode
      )
      used_playback_safe_alternative = alternative.present?
      alternative
    end

    if used_playback_safe_alternative
      Rails.logger.info("[ContentStreamingService] Playback-safe alternative resolved for imdb_id=#{imdb_id} filename=#{result[:filename]}")
    else
      result = resolve_stream(selected_stream)
    end

    if result
      unless used_playback_safe_alternative
        Rails.logger.info("[ContentStreamingService] User-selected stream resolved for imdb_id=#{imdb_id} filename=#{result[:filename]}")
      end
    else
      Rails.logger.warn("[ContentStreamingService] User-selected stream failed to resolve, falling back for imdb_id=#{imdb_id}")
      result = resolve_fallback_streams(resolve_url, imdb_id, type, season: season, episode: episode)
      if result
        Rails.logger.info("[ContentStreamingService] Fallback stream resolved for imdb_id=#{imdb_id} filename=#{result[:filename]}")
      else
        Rails.logger.warn("[ContentStreamingService] No valid stream found via fallback for imdb_id=#{imdb_id}")
      end
    end

    if result
      stream_result(result, imdb_id: imdb_id, type: type, season: season, episode: episode)
    else
      ServiceResult.failure("Could not resolve the selected stream. It may be blocked or unavailable.")
    end
  end

  private

  BLOCKED_PATTERNS = /downloading|infringing|failed|removed|blocked/i

  # Fetch streams from all configured providers in parallel, merging results.
  # All providers are queried concurrently — a slow or failed Comet doesn't
  # block Torrentio. Results are combined so the best stream wins regardless
  # of which provider found it.
  def fetch_streams(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("No stream providers available") if @providers.empty?

    Rails.logger.info("[ContentStreamingService] fetch_streams: #{@providers.length} providers for #{imdb_id} (#{type})")

    threads = @providers.map do |provider|
      Thread.new do
        name = provider.class.name
        start = Time.current
        result = provider.streams(
          imdb_id,
          type,
          season: season,
          episode: episode,
          title: nil,
          preferred_languages: @user.preferred_stream_languages,
          default_language: @user.default_stream_language
        )
        elapsed = ((Time.current - start) * 1000).round
        count = result.success? ? result.data.length : 0
        Rails.logger.info("[ContentStreamingService] #{name} returned #{count} streams in #{elapsed}ms")
        result
      end
    end
    results = threads.map(&:value)

    all_streams = []
    results.each do |result|
      all_streams.concat(result.data) if result&.success?
    end

    ServiceResult.success(all_streams)
  end

  def stream_candidates(streams)
    streams.first(MAX_STREAM_ATTEMPTS).select { |s| s[:resolve_url].present? }
  end

  def resolve_playback_safe_alternative(selected_resolve_url, imdb_id, type, duration:, season:, episode:)
    streams_result = fetch_streams(imdb_id, type, season: season, episode: episode)
    return if streams_result.failure?

    candidates = streams_result.data
      .reject { |stream| stream[:resolve_url] == selected_resolve_url }
      .select { |stream| playback_safe_candidate?(stream, duration) }
      .sort_by { |stream| playback_candidate_sort_key(stream) }
      .first(MAX_STREAM_ATTEMPTS)

    resolve_first_valid(candidates)
  end

  def oversized_transcode_source?(stream, duration)
    return false unless HEAVY_VIDEO_CODECS.include?(stream[:video_codec])

    bitrate = estimated_bitrate(stream[:raw_size], duration)
    bitrate && bitrate > MAX_TRANSCODE_SOURCE_BITRATE_BPS
  end

  def playback_safe_candidate?(stream, duration)
    bitrate = estimated_bitrate(stream[:raw_size], duration)
    return bitrate <= MAX_TRANSCODE_SOURCE_BITRATE_BPS if bitrate

    # Unknown sizes cannot be proven sustainable, but a direct-play or
    # stream-copy candidate removes the expensive video encode bottleneck.
    stream[:compatibility_score].to_i >= 2
  end

  def playback_candidate_sort_key(stream)
    [
      stream[:language_score].to_i,
      -stream[:compatibility_score].to_i,
      QUALITY_ORDER.fetch(stream[:quality].to_s, QUALITY_ORDER["Unknown"]),
      -positive_number(stream[:raw_size]).to_i
    ]
  end

  def estimated_bitrate(raw_size, duration)
    bytes = positive_number(raw_size)
    seconds = positive_number(duration)
    return unless bytes && seconds && seconds >= 60 && seconds <= 24.hours.to_i

    bytes * 8 / seconds
  end

  def positive_number(value)
    number = Float(value, exception: false)
    number if number&.positive?
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
    candidates.group_by { |stream| stream[:language_score].to_i }.sort_by(&:first).each do |_, language_group|
      language_group.each_slice(RESOLVE_BATCH_SIZE) do |batch|
        winner = resolve_first_valid_batch(batch)
        return winner if winner
      end
    end

    nil
  end

  def resolve_first_valid_batch(candidates)
    results = Queue.new
    threads = candidates.map do |stream|
      Thread.new(stream) do |s|
        results << resolve_stream(s)
      rescue StandardError => e
        Rails.logger.warn("[ContentStreamingService] Candidate resolution failed: #{e.class.name}")
        results << nil
      end
    end

    # Consume completion order, not candidate order. Joining threads in array
    # order made a slow first URL hide a winner that another request had already
    # produced, holding "Finding stream..." open until the slow URL timed out.
    candidates.length.times do
      resolved = results.pop
      return resolved if resolved
    end

    nil
  ensure
    threads&.each(&:kill)
    threads&.each { |thread| thread.join(0.1) }
  end

  def verify_resolve_url(resolve_url)
    return nil unless allowed_resolve_url?(resolve_url)

    response = with_resolve_retries { resolve_faraday_for(resolve_url).get(resolve_url) }
    return nil unless response

    if [ 301, 302, 303, 307, 308 ].include?(response.status)
      location = response.headers["location"]
      return nil if location.blank?
      return nil if location.match?(BLOCKED_PATTERNS)
      return nil unless http_url?(location)
      # The final streaming URL must be a RealDebrid CDN URL — the
      # resolve URL is an intermediary on the provider (Torrentio/Comet)
      # host, but the Location it redirects to should be the RD download
      # host.  Reject anything else to prevent an untrusted/compromised
      # provider from redirecting the server (which attaches the user's
      # RD API key as a Bearer header) to an attacker-controlled host.
      return nil unless realdebrid_cdn_url?(location)
      filename = location.split("/").last.to_s
      return nil if filename.match?(BLOCKED_PATTERNS)
      { streaming_url: location, filename: filename }
    elsif [ 200, 206 ].include?(response.status)
      # Some Comet playback endpoints return 200 with a tiny trailer/
      # placeholder MP4 instead of 302-redirecting to the actual RD
      # download URL.  Only accept 200 responses from RD CDN hosts —
      # provider hosts that return 200 are almost certainly serving a
      # trailer/placeholder, not the real content.
      return nil unless realdebrid_cdn_url?(resolve_url)
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
    @allowed_resolve_origins ||= StreamProvider.resolve_base_urls.filter_map do |url|
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

  # The final destination after a resolve-URL redirect must be a
  # RealDebrid CDN host.  Provider hosts (Comet/Torrentio) are
  # intermediaries only — they should never appear as the final
  # streaming_url because the transcode/direct_stream proxies attach
  # the user's RD API key as a Bearer header to whatever host they
  # fetch, and we don't want to send the key to a provider host.
  REALDEBRID_CDN_HOSTS = %w[
    real-debrid.com
    download.real-debrid.com
    streaming.real-debrid.com
  ].freeze

  def realdebrid_cdn_url?(url)
    host = URI.parse(url.to_s).host.to_s.downcase
    REALDEBRID_CDN_HOSTS.any? { |cdn| host == cdn || host.end_with?(".#{cdn}") }
  rescue URI::InvalidURIError
    false
  end

  # Pick the right Faraday client for a resolve URL.  Comet resolve URLs
  # (playback endpoints on the private Comet host) must NOT go through
  # TORRENTIO_PROXY — that proxy is for Torrentio only and blocks traffic
  # to the Comet host.
  def resolve_faraday_for(resolve_url)
    if comet_url?(resolve_url)
      resolve_faraday_direct
    else
      resolve_faraday
    end
  end

  def comet_url?(resolve_url)
    CometService.comet_url.present? && resolve_url.to_s.start_with?(CometService.comet_url)
  end

  def resolve_faraday_direct
    @resolve_faraday_direct ||= Faraday.new do |f|
      f.adapter Faraday.default_adapter
      f.options.timeout = 15
      f.options.open_timeout = 5
    end
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
