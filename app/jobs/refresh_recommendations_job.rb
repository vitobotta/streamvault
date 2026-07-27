# frozen_string_literal: true

class RefreshRecommendationsJob < ApplicationJob
  queue_as :default

  DEBOUNCE_TTL = 10.minutes

  # Refreshes the user's cached TMDB recommendations. Progress writes
  # debounce this job so playback never triggers repeated API fan-out.
  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user
    return if ENV["TMDB_READ_ACCESS_TOKEN"].blank?

    RecommendationService.refresh(user)
  rescue StandardError => e
    Rails.logger.error("[RefreshRecommendationsJob] error: #{e.message}")
  end

  # Debounce: only enqueue if the lock wasn't already set.  Uses
  # unless_exist: true so the read+write is atomic against Solid Cache
  # (DB-backed) — two concurrent callers can't both see nil and both
  # enqueue, which the old read-then-write pattern allowed.
  def self.enqueue_debounced(user_id)
    lock_key = "recommendations:job:#{user_id}"
    return unless Rails.cache.write(lock_key, true, expires_in: DEBOUNCE_TTL, unless_exist: true)

    perform_later(user_id)
  end
end
