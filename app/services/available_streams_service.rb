# frozen_string_literal: true

require "digest"

class AvailableStreamsService
  CACHE_TTL = 60.seconds

  def initialize(user, providers: nil, cache: Rails.cache, logger: Rails.logger)
    @user = user
    @providers = providers || StreamProvider.providers(
      rd_api_key: user&.effective_realdebrid_api_key,
      torbox_api_key: user&.effective_torbox_api_key,
      debrid_service: user&.effective_debrid_service
    )
    @cache = cache
    @logger = logger
  end

  def call(imdb_id:, type:, season: nil, episode: nil, title: nil)
    cache_key = cache_key_for(imdb_id, type, season, episode)
    cached = @cache.read(cache_key)
    return cached if cached

    result = fetch_streams(imdb_id, type, season, episode, title)
    @cache.write(cache_key, result, expires_in: CACHE_TTL) if result.success?
    result
  end

  private

  def cache_key_for(imdb_id, type, season, episode)
    language_key = Array(@user.stream_language_priority).join(",")
    # A team key can change without touching the user row, so include a
    # fingerprint of every usable credential instead of relying on the cache
    # version alone.
    credential_key = Digest::SHA256.hexdigest(
      [ @user.effective_debrid_service, @user.effective_realdebrid_api_key.to_s, @user.effective_torbox_api_key.to_s ].join(":")
    )[0, 12]
    "streams/v4/#{@user.cache_key_with_version}/#{credential_key}/#{imdb_id}/#{type}/#{season}/#{episode}/#{language_key}"
  end

  def fetch_streams(imdb_id, type, season, episode, title)
    @logger.info("[AvailableStreamsService] #{@providers.length} providers for #{imdb_id} (#{type})")

    results = @providers.map do |provider|
      Thread.new { fetch_provider(provider, imdb_id, type, season, episode, title) }
    end.map(&:value)

    streams = results.filter_map { |result| result.data if result&.success? }.flatten(1)
    streams = deduplicate(streams)
    streams.empty? ? ServiceResult.failure("No streams available") : ServiceResult.success(streams)
  end

  # Every debrid variant of an addon returns the same torrents, so keep the
  # first copy: providers for the account's preferred service run first.
  def deduplicate(streams)
    seen = {}
    streams.each_with_object([]) do |stream, unique|
      key = torrent_key(stream)
      next if key && seen[key]

      seen[key] = true if key
      unique << stream
    end
  end

  def torrent_key(stream)
    info_hash = stream.respond_to?(:info_hash) ? stream.info_hash : stream[:info_hash]
    return if info_hash.blank?

    file_idx = stream.respond_to?(:file_idx) ? stream.file_idx : stream[:file_idx]
    [ info_hash, file_idx ].join(":")
  end

  def fetch_provider(provider, imdb_id, type, season, episode, title)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = provider.streams(
      imdb_id,
      type,
      season: season,
      episode: episode,
      title: title,
      preferred_languages: @user.preferred_stream_languages,
      default_language: @user.default_stream_language
    )
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    count = result&.success? ? result.data.length : 0
    @logger.info("[AvailableStreamsService] #{provider.class.name} returned #{count} streams in #{elapsed_ms}ms")
    return result unless result&.success?

    ServiceResult.success(
      result.data.map { |stream| StreamCandidate.from(stream, provider: provider.class.name) }
    )
  rescue StandardError => e
    @logger.warn("[AvailableStreamsService] #{provider.class.name} failed: #{e.class}: #{e.message}")
    ServiceResult.failure(e.message)
  end
end
