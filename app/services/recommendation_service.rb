# frozen_string_literal: true

require "set"

class RecommendationService
  CACHE_TTL = 24.hours
  MAX_RECOMMENDATIONS = 20
  MAX_HISTORY_FOR_RECS = 20
  MAX_RECS_PER_SOURCE = 5

  def self.for(user)
    items = Rails.cache.read(cache_key(user.id))
    unless items
      RefreshRecommendationsJob.enqueue_debounced(user.id)
      return ServiceResult.success([])
    end

    excluded = excluded_imdb_ids(user).to_set
    ServiceResult.success(items.reject { |item| excluded.include?(item[:imdb_id]) })
  end

  def self.refresh(user)
    result = build_recommendations(user)
    Rails.cache.write(cache_key(user.id), result.data, expires_in: CACHE_TTL) if result.success?
    result
  end

  def self.excluded_imdb_ids(user)
    watched = user.playback_progresses.distinct.pluck(:imdb_id)
    collected = user.collection_entries.distinct.pluck(:imdb_id)
    (watched + collected).uniq
  end

  def self.build_recommendations(user)
    return ServiceResult.success([]) if ENV["TMDB_READ_ACCESS_TOKEN"].blank?

    watched_ids = watched_imdb_ids(user)
    return ServiceResult.success([]) if watched_ids.empty?

    tmdb = TmdbService.new
    excluded = excluded_imdb_ids(user).to_set
    results = []
    seen = Set.new
    sources = watched_ids.filter_map do |imdb_id|
      response = tmdb.recommendations_for_imdb_id(imdb_id, limit: MAX_RECS_PER_SOURCE)
      response.data if response.success?
    end

    MAX_RECS_PER_SOURCE.times do |source_index|
      sources.each do |items|
        item = items[source_index]
        next if item.nil? || item[:imdb_id].blank?
        next if seen.include?(item[:tmdb_id]) || excluded.include?(item[:imdb_id])

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
  private_class_method :build_recommendations

  def self.watched_imdb_ids(user)
    user.playback_progresses
      .group(:imdb_id)
      .order(Arel.sql("MAX(watched_at) DESC"))
      .limit(MAX_HISTORY_FOR_RECS)
      .pluck(:imdb_id)
  end
  private_class_method :watched_imdb_ids

  def self.cache_key(user_id)
    "recommendations/user/#{user_id}"
  end
  private_class_method :cache_key
end
