# frozen_string_literal: true

class RecommendationService
  MAX_RECOMMENDATIONS = 20
  MAX_GENRES_TO_QUERY = 3
  MAX_HISTORY_FOR_GENRES = 10

  # Returns recommended content based on the user's watch history.
  #
  # Strategy: extract genres from recently watched content via Cinemeta
  # metadata, then fetch Cinemeta's top-rated catalog filtered by those
  # genres. Excludes content the user has already watched or added to
  # their library/wishlist. Returns a mix of movies and shows.
  def self.recommendations(user)
    watched_ids = watched_imdb_ids(user)
    return ServiceResult.success([]) if watched_ids.empty?

    genres = top_genres(watched_ids)
    return ServiceResult.success([]) if genres.empty?

    exclude_ids = exclude_set(user)

    torrentio = TorrentioService.new
    results = []
    genres.first(MAX_GENRES_TO_QUERY).each do |genre|
      %w[movie show].each do |type|
        break if results.length >= MAX_RECOMMENDATIONS
        catalog_result = torrentio.catalog(type, "top", genre: genre, limit: 30)
        next if catalog_result.failure?

        catalog_result.data.each do |item|
          break if results.length >= MAX_RECOMMENDATIONS
          next if exclude_ids.include?(item[:imdb_id])
          next if results.any? { |r| r[:imdb_id] == item[:imdb_id] }
          results << item
        end
      end
    end

    ServiceResult.success(results)
  rescue StandardError => e
    Rails.logger.error("[RecommendationService] error: #{e.message}")
    ServiceResult.success([])
  end

  private

  # Unique IMDb IDs from the user's recent watch history (show_imdb_id
  # for episodes, imdb_id for movies).
  def self.watched_imdb_ids(user)
    user.watch_history_entries
      .order(watched_at: :desc)
      .limit(MAX_HISTORY_FOR_GENRES)
      .map { |e| e.show_imdb_id.presence || e.imdb_id }
      .uniq
  end

  # Fetch genres for the given IMDb IDs via Cinemeta metadata, count
  # occurrences, and return the most frequent genres.
  def self.top_genres(imdb_ids)
    torrentio = TorrentioService.new
    genre_counts = Hash.new(0)

    imdb_ids.each do |imdb_id|
      # Try movie first, then show — we don't know the type from IMDb ID alone
      %w[movie show].each do |type|
        result = torrentio.metadata(imdb_id, type)
        next if result.failure?

        genres = result.data[:genre]&.split(", ")&.map(&:strip)
        genres&.each { |g| genre_counts[g] += 1 }
        break # metadata found for this type, stop trying
      end
    end

    genre_counts.sort_by { |_, count| -count }.map(&:first)
  end

  # IMDb IDs to exclude from recommendations: everything the user has
  # watched, plus library and wishlist entries.
  def self.exclude_set(user)
    watched = user.watch_history_entries.pluck(:imdb_id, :show_imdb_id).flatten.compact
    library = user.library_entries.pluck(:imdb_id)
    wishlist = user.wishlist_entries.pluck(:imdb_id)
    (watched + library + wishlist).to_set
  end
end
