# frozen_string_literal: true

module Catalog
  class CinemetaClient
    BASE_URL = "https://v3-cinemeta.strem.io"
    CACHE_TTL = 1.hour

    def initialize(connection: nil, cache: Rails.cache, ratings: Catalog::OmdbClient.new, logger: Rails.logger)
      @connection = connection || Faraday.new(url: BASE_URL) do |faraday|
        faraday.response :json
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
        faraday.proxy = ENV["CINEMETA_PROXY"] if ENV["CINEMETA_PROXY"].present?
      end
      @cache = cache
      @ratings = ratings
      @logger = logger
    end

    def search(query)
      return ServiceResult.failure("Query cannot be blank") if query.blank?

      encoded = URI.encode_www_form_component(query)
      results = %w[movie series].flat_map do |type|
        response = @connection.get("catalog/#{type}/top/search=#{encoded}.json")
        next [] unless response.success? && response.body.is_a?(Hash)

        Array(response.body["metas"]).map { |meta| normalize_summary(meta, type) }
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed
        []
      end
      ServiceResult.success(results)
    rescue StandardError => e
      @logger.error("[Catalog::CinemetaClient] search failed: #{e.class}: #{e.message}")
      ServiceResult.failure("Search failed")
    end

    def metadata(imdb_id, type)
      return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

      cache_key = "catalog/cinemeta/meta/#{type}/#{imdb_id}"
      cached = @cache.read(cache_key)
      return ServiceResult.success(cached) if cached

      response = @connection.get("meta/#{cinemeta_type(type)}/#{imdb_id}.json")
      return ServiceResult.failure("Metadata not found") unless response.success? && response.body.is_a?(Hash) && response.body["meta"]

      result = normalize_metadata(response.body["meta"], type).merge(optional_ratings(imdb_id))
      @cache.write(cache_key, result, expires_in: CACHE_TTL)
      ServiceResult.success(result)
    rescue Faraday::TimeoutError
      ServiceResult.failure("Metadata request timed out")
    rescue Faraday::ConnectionFailed
      ServiceResult.failure("Could not connect to metadata service")
    rescue StandardError => e
      @logger.error("[Catalog::CinemetaClient] metadata failed: #{e.class}: #{e.message}")
      ServiceResult.failure("Failed to fetch metadata")
    end

    def popular(type, limit: 20)
      catalog(type, "top", limit: limit)
    end

    def trending(type, limit: 20)
      catalog(type, "year", genre: Date.current.year.to_s, limit: limit)
    end

    def featured(type, limit: 20)
      catalog(type, "imdbRating", limit: limit)
    end

    def catalog(type, catalog_id, genre: nil, limit: 20)
      path = "catalog/#{cinemeta_type(type)}/#{catalog_id}.json"
      path += "?genre=#{CGI.escape(genre)}" if genre.present?
      cache_key = "catalog/cinemeta/#{type}/#{catalog_id}/#{genre}/#{limit}"
      items = @cache.fetch(cache_key, expires_in: CACHE_TTL, race_condition_ttl: 30.seconds) do
        response = @connection.get(path)
        next [] unless response.success? && response.body.is_a?(Hash)

        Array(response.body["metas"]).first(limit).map { |meta| normalize_summary(meta, type.to_s) }
      end
      ServiceResult.success(items)
    rescue StandardError => e
      @logger.error("[Catalog::CinemetaClient] catalog failed: #{e.class}: #{e.message}")
      ServiceResult.success([])
    end

  private

    def optional_ratings(imdb_id)
      @ratings.ratings(imdb_id)
    rescue StandardError => e
      @logger.warn("[Catalog::CinemetaClient] optional ratings failed: #{e.class}: #{e.message}")
      {}
    end

    def cinemeta_type(type)
      type.to_s == "show" ? "series" : type.to_s
    end

    def normalize_summary(meta, type)
      {
        imdb_id: meta["imdb_id"] || meta["id"],
        title: meta["name"],
        year: meta["releaseInfo"] || meta["year"],
        type: type.to_s == "series" ? "show" : type.to_s,
        poster_url: meta["poster"],
        imdb_rating: meta["imdbRating"]
      }
    end

    def normalize_metadata(meta, type)
      {
        imdb_id: meta["imdb_id"] || meta["id"],
        title: meta["name"],
        year: meta["year"] || meta["releaseInfo"],
        type: type,
        poster_url: meta["poster"],
        background_url: meta["background"],
        plot: meta["description"],
        genre: Array(meta["genres"]).join(", ").presence,
        director: Array(meta["director"]).join(", ").presence,
        actors: Array(meta["cast"]).join(", ").presence,
        rated: meta["certification"],
        imdb_rating: meta["imdbRating"],
        runtime: meta["runtime"],
        runtime_seconds: parse_runtime_seconds(meta["runtime"]),
        total_seasons: Array(meta["videos"]).filter_map { |video| video["season"] }.max,
        episodes: normalize_episodes(meta["videos"])
      }
    end

    def normalize_episodes(videos)
      Array(videos).select { |video| video["episode"] }.map do |video|
        {
          season: video["season"], episode: video["episode"],
          title: video["name"].presence || "Episode #{video['episode']}",
          released: video["released"]&.to_date&.to_s,
          imdb_id: video["id"], overview: video["overview"], runtime: video["runtime"],
          runtime_seconds: parse_runtime_seconds(video["runtime"])
        }
      end
    end

    def parse_runtime_seconds(runtime)
      value = runtime.to_s.strip
      return if value.blank?

      if (iso = value.match(/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\z/i))
        total = (iso[1].to_i * 3600) + (iso[2].to_i * 60) + iso[3].to_i
        return total if total.positive?
      end

      hours = value[/(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\b/i, 1].to_f
      minutes = value[/(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)\b/i, 1].to_f
      return ((hours * 3600) + (minutes * 60)).round if hours.positive? || minutes.positive?

      numeric_minutes = value[/\A(\d+(?:\.\d+)?)\z/, 1]&.to_f
      (numeric_minutes * 60).round if numeric_minutes&.positive?
    end
  end
end
