# frozen_string_literal: true

require "set"

class RecommendationService
  MAX_RECOMMENDATIONS = 20
  MAX_HISTORY_FOR_RECS = 20
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
    exclude_ids = excluded_imdb_ids(user).to_set
    results = []
    seen = Set.new

    # Fetch every recent, distinct seed before selecting results. Interleaving
    # the sources below prevents the first few watched titles from filling the
    # entire recommendation row and gives movies and shows equal opportunity.
    sources = watched_ids.filter_map do |imdb_id|
      tmdb_recs = tmdb.recommendations_for_imdb_id(
        imdb_id,
        limit: MAX_RECS_PER_SOURCE
      )
      tmdb_recs.data if tmdb_recs.success?
    end

    MAX_RECS_PER_SOURCE.times do |source_index|
      sources.each do |items|
        item = items[source_index]
        next if item.nil?
        next if item[:imdb_id].blank?
        next if seen.include?(item[:tmdb_id])
        next if exclude_ids.include?(item[:imdb_id])

        seen.add(item[:tmdb_id])
        results << item
        break if results.length >= MAX_RECOMMENDATIONS
      end
      break if results.length >= MAX_RECOMMENDATIONS
    end

    ServiceResult.success(results)
  rescue StandardError => e
    Rails.logger.error("[RecommendationService] error: #{e.message}")
    ServiceResult.success([])
  end

  private_class_method

  def self.watched_imdb_ids(user)
    content_id = Arel.sql("COALESCE(show_imdb_id, imdb_id)")
    user.watch_history_entries
      .group(content_id)
      .order(Arel.sql("MAX(watched_at) DESC"))
      .limit(MAX_HISTORY_FOR_RECS)
      .pluck(content_id)
  end

  # Current exclusions are also applied when rendering stored recommendations,
  # so a debounced refresh can never leave newly watched content visible.
  def self.excluded_imdb_ids(user)
    content_id = Arel.sql("COALESCE(show_imdb_id, imdb_id)")
    watched = user.watch_history_entries.distinct.pluck(content_id)
    library = user.library_entries.pluck(:imdb_id)
    wishlist = user.wishlist_entries.pluck(:imdb_id)
    (watched + library + wishlist).uniq
  end
end
