# frozen_string_literal: true

require "set"

class RecommendationService
  MAX_RECOMMENDATIONS = 20
  MAX_HISTORY_FOR_RECS = 8
  MAX_RECS_PER_SOURCE = 5

  # Returns recommended content based on the user's watch history
  # using TMDB's recommendation API (collaborative filtering —
  # "because you watched X" style, not genre matching).
  #
  # For each recently watched title:
  #   1. Resolve its TMDB ID from the IMDb ID
  #   2. Fetch TMDB's /recommendations endpoint (viewers of this
  #      also watched...)
  #   3. Map results back to IMDb IDs
  #
  # Excludes content already watched, in library, or on wishlist.
  # Returns a mix of movies and shows.
  def self.recommendations(user)
    return ServiceResult.success([]) if ENV["TMDB_READ_ACCESS_TOKEN"].blank?

    watched_ids = watched_imdb_ids(user)
    return ServiceResult.success([]) if watched_ids.empty?

    tmdb = TmdbService.new
    exclude_ids = exclude_set(user)
    results = []
    seen = Set.new

    watched_ids.each do |imdb_id|
      break if results.length >= MAX_RECOMMENDATIONS
      tmdb_recs = tmdb.recommendations_for_imdb_id(imdb_id)
      next if tmdb_recs.failure?

      tmdb_recs.data.first(MAX_RECS_PER_SOURCE).each do |item|
        break if results.length >= MAX_RECOMMENDATIONS
        tmdb_id = item[:tmdb_id]
        next if seen.include?(tmdb_id)
        next if exclude_ids.include?(item[:imdb_id])
        next if item[:imdb_id].blank?
        seen.add(tmdb_id)
        results << item
      end
    end

    ServiceResult.success(results)
  rescue StandardError => e
    Rails.logger.error("[RecommendationService] error: #{e.message}")
    ServiceResult.success([])
  end

  private_class_method

  def self.watched_imdb_ids(user)
    user.watch_history_entries
      .order(watched_at: :desc)
      .limit(MAX_HISTORY_FOR_RECS)
      .map { |e| e.show_imdb_id.presence || e.imdb_id }
      .uniq
  end

  def self.exclude_set(user)
    watched = user.watch_history_entries.pluck(:imdb_id, :show_imdb_id).flatten.compact
    library = user.library_entries.pluck(:imdb_id)
    wishlist = user.wishlist_entries.pluck(:imdb_id)
    (watched + library + wishlist).to_set
  end
end
