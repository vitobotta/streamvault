# frozen_string_literal: true

class AvailableStreamsService
  CACHE_TTL = 60.seconds

  def initialize(user, providers: nil, cache: Rails.cache, logger: Rails.logger)
    @user = user
    @providers = providers || StreamProvider.providers(rd_api_key: user&.realdebrid_api_key)
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
    "streams/#{imdb_id}/#{type}/#{season}/#{episode}/#{language_key}"
  end

  def fetch_streams(imdb_id, type, season, episode, title)
    @logger.info("[AvailableStreamsService] #{@providers.length} providers for #{imdb_id} (#{type})")

    results = @providers.map do |provider|
      Thread.new { fetch_provider(provider, imdb_id, type, season, episode, title) }
    end.map(&:value)

    streams = results.filter_map { |result| result.data if result&.success? }.flatten(1)
    streams.empty? ? ServiceResult.failure("No streams available") : ServiceResult.success(streams)
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
    result
  rescue StandardError => e
    @logger.warn("[AvailableStreamsService] #{provider.class.name} failed: #{e.class}: #{e.message}")
    ServiceResult.failure(e.message)
  end
end
