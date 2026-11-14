# frozen_string_literal: true

module ParentalControls
  # Resolves the minimum viewer age for a title (by IMDb ID) from the
  # available rating sources:
  #
  #   1. OMDB "Rated" (needs OMDB_API_KEY)
  #   2. TMDB US certification (movie release dates / TV content ratings,
  #      needs TMDB_READ_ACCESS_TOKEN)
  #
  # (Cinemeta metadata is intentionally not consulted: its "certification"
  # field is not populated in practice.)
  #
  # The resolved age is cached per IMDb ID.  When no source can produce a
  # certification the result is Rating::UNKNOWN_AGE (fail-closed): a child
  # account cannot see or play unrated content unless its max_rating_age
  # is 18.
  class RatingResolver
    KNOWN_TTL = 1.week
    UNKNOWN_TTL = 1.day
    # Bump when the certification→age mapping changes so previously
    # resolved ages (cached for up to a week) cannot outlive a fix.
    CACHE_VERSION = 2

    # True when at least one certification source can actually be queried.
    # Without one, unrated titles resolve to UNKNOWN_AGE and a child account
    # below 18 sees an empty catalogue, which looks like a bug rather than a
    # configuration gap.  This asks the same two services the instance uses,
    # so a present-but-unusable TMDB token is reported as missing.
    def self.sources_configured?
      cache_key = [ ENV["OMDB_API_KEY"], ENV["TMDB_READ_ACCESS_TOKEN"] ]
      @configuration_cache ||= {}
      return @configuration_cache[cache_key] if @configuration_cache.key?(cache_key)

      @configuration_cache[cache_key] = omdb_configured? || tmdb_configured?
    end

    def self.omdb_configured?
      Catalog::OmdbClient.new.configured?
    end

    def self.tmdb_configured?
      return false if ENV["TMDB_READ_ACCESS_TOKEN"].blank?

      TmdbService.new
      true
    rescue StandardError
      false
    end

    def initialize(omdb: Catalog::OmdbClient.new, tmdb: :auto, cache: Rails.cache, logger: Rails.logger)
      @omdb = omdb
      @tmdb = tmdb == :auto ? build_tmdb_service : tmdb
      @cache = cache
      @logger = logger
    end

    # Returns the minimum viewer age (0..18) for the given IMDb ID.
    def min_age(imdb_id)
      return Rating::UNKNOWN_AGE if imdb_id.blank?

      cache_key = "parental/rating_age/v#{CACHE_VERSION}/#{imdb_id}"
      cached = @cache.read(cache_key)
      return cached if cached.is_a?(Integer)

      certification = resolve_certification(imdb_id)
      age = Rating.min_age_for(certification)
      @cache.write(cache_key, age, expires_in: certification.present? ? KNOWN_TTL : UNKNOWN_TTL)
      age
    end

    private

    def resolve_certification(imdb_id)
      from_omdb(imdb_id).presence || from_tmdb(imdb_id).presence
    end

    def from_omdb(imdb_id)
      return nil unless @omdb.respond_to?(:configured?) ? @omdb.configured? : ENV["OMDB_API_KEY"].present?

      @omdb.ratings(imdb_id)[:rated].to_s.strip.presence
    rescue StandardError => e
      @logger.warn("[ParentalControls::RatingResolver] OMDB lookup failed: #{e.class}: #{e.message}")
      nil
    end

    def from_tmdb(imdb_id)
      return nil unless @tmdb

      @tmdb.certification_for_imdb_id(imdb_id).to_s.strip.presence
    rescue StandardError => e
      @logger.warn("[ParentalControls::RatingResolver] TMDB lookup failed: #{e.class}: #{e.message}")
      nil
    end

    # The env check is deliberate: sources_configured? already instantiates the
    # service to report whether it is usable, and resolving a title should not
    # build it twice.
    def build_tmdb_service
      return nil if ENV["TMDB_READ_ACCESS_TOKEN"].blank?

      TmdbService.new
    rescue StandardError => e
      @logger.warn("[ParentalControls::RatingResolver] TMDB unavailable: #{e.class}: #{e.message}")
      nil
    end
  end
end
