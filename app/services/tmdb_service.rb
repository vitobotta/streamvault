# frozen_string_literal: true

require "set"

# TMDB API client for movie/TV recommendations.
#
# Uses TMDB's v4 bearer token (Read Access Token). The token is
# configured via TMDB_READ_ACCESS_TOKEN in .env — get one at
# https://www.themoviedb.org/settings/api.
#
# Key endpoints:
#   /find/{imdb_id}?external_source=imdb_id → resolve TMDB ID
#   /movie/{tmdb_id}/recommendations       → "viewers also watched"
#   /tv/{tmdb_id}/recommendations           → same for shows
#   /movie/{tmdb_id}/external_ids           → get IMDb ID back
#   /tv/{tmdb_id}/external_ids
class TmdbService
  BASE_URL = "https://api.themoviedb.org/3"
  POSTER_BASE = "https://image.tmdb.org/t/p/w500"

  def initialize
    @token = ENV.fetch("TMDB_READ_ACCESS_TOKEN", "")
    raise "TMDB_READ_ACCESS_TOKEN not configured" if @token.blank?

    @conn = Faraday.new(url: BASE_URL) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 10
      f.options.open_timeout = 5
      f.headers["Authorization"] = "Bearer #{@token}"
    end
  end

  # Given an IMDb ID, return recommendations from TMDB's
  # "viewers also watched" endpoint. Automatically detects whether
  # the ID is a movie or TV show via the /find endpoint.
  #
  # Returns ServiceResult<Array<Hash>> where each hash has:
  #   tmdb_id, imdb_id, title, poster_url, type, year
  def recommendations_for_imdb_id(imdb_id)
    return ServiceResult.failure("IMDb ID required") if imdb_id.blank?

    tmdb_info = find_by_imdb_id(imdb_id)
    return ServiceResult.failure("Not found on TMDB") if tmdb_info.nil?

    tmdb_id = tmdb_info[:tmdb_id]
    media_type = tmdb_info[:type]

    recs = fetch_recommendations(tmdb_id, media_type)
    return ServiceResult.success([]) if recs.empty?

    # Resolve IMDb IDs for all recommendations in one batch
    imdb_ids = recs.map { |r| fetch_imdb_id(r[:tmdb_id], media_type) }

    results = recs.zip(imdb_ids).map do |rec, imdb_id|
      next nil if imdb_id.blank?
      {
        tmdb_id: rec[:tmdb_id],
        imdb_id: imdb_id,
        title: rec[:title],
        poster_url: rec[:poster_url],
        type: media_type == "movie" ? "movie" : "show",
        year: rec[:year]
      }
    end.compact

    ServiceResult.success(results)
  rescue Faraday::TimeoutError
    Rails.logger.error("[TmdbService] request timed out")
    ServiceResult.failure("TMDB request timed out")
  rescue Faraday::ConnectionFailed => e
    Rails.logger.error("[TmdbService] connection failed: #{e.message}")
    ServiceResult.failure("Could not connect to TMDB")
  rescue StandardError => e
    Rails.logger.error("[TmdbService] error: #{e.message}")
    ServiceResult.failure("TMDB error: #{e.message}")
  end

  private

  # Resolve IMDb ID → TMDB ID and media type (movie or tv).
  def find_by_imdb_id(imdb_id)
    response = @conn.get("find/#{imdb_id}", { external_source: "imdb_id" })
    return nil unless response.success? && response.body.is_a?(Hash)

    movie = response.body["movie_results"]&.first
    return { tmdb_id: movie["id"], type: "movie", title: movie["title"] } if movie

    tv = response.body["tv_results"]&.first
    return { tmdb_id: tv["id"], type: "tv", title: tv["name"] } if tv

    nil
  end

  # Fetch recommendations from TMDB's collaborative filtering endpoint.
  def fetch_recommendations(tmdb_id, media_type)
    endpoint = "#{media_type}/#{tmdb_id}/recommendations"
    response = @conn.get(endpoint, { page: 1 })
    return [] unless response.success? && response.body.is_a?(Hash)

    (response.body["results"] || []).map do |r|
      poster = r["poster_path"] ? "#{POSTER_BASE}#{r['poster_path']}" : nil
      {
        tmdb_id: r["id"],
        title: r["title"] || r["name"],
        poster_url: poster,
        year: extract_year(r)
      }
    end
  end

  # Fetch the IMDb ID for a TMDB movie/TV entry via external_ids.
  def fetch_imdb_id(tmdb_id, media_type)
    response = @conn.get("#{media_type}/#{tmdb_id}/external_ids")
    return nil unless response.success? && response.body.is_a?(Hash)
    response.body["imdb_id"].presence
  end

  def extract_year(result)
    date = result["release_date"] || result["first_air_date"]
    date&.[](0..3)
  end
end
