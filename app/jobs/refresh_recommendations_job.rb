class RefreshRecommendationsJob < ApplicationJob
  queue_as :default

  # Fetches personalised recommendations from TMDB and caches them
  # as JSON in Rails.cache. The home page reads from cache instead of
  # making live TMDB API calls on every page load.
  #
  # Triggered after each progress save (every 5s during playback) —
  # but debounced via a short lock so it only runs once per 10 minutes
  # per user, not on every single progress tick.
  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user
    return if ENV["TMDB_READ_ACCESS_TOKEN"].blank?

    result = RecommendationService.recommendations(user)
    recommendations = result.success? ? result.data : []

    Rails.cache.write(self.class.cache_key(user_id), recommendations, expires_in: 1.hour)
  rescue StandardError => e
    Rails.logger.error("[RefreshRecommendationsJob] error: #{e.message}")
  end

  # Cache key for a user's recommendations.
  def self.cache_key(user_id)
    "recommendations:#{user_id}"
  end

  # Debounce: only enqueue if the job hasn't been enqueued recently.
  # Called with a lock so rapid progress saves (every 5s) don't
  # enqueue redundant jobs.
  def self.enqueue_debounced(user_id)
    lock_key = "recommendations:job:#{user_id}"
    return if Rails.cache.read(lock_key)

    Rails.cache.write(lock_key, true, expires_in: 10.minutes)
    perform_later(user_id)
  end
end
