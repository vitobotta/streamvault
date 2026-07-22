# frozen_string_literal: true

class WatchHistoryCleanupService
  def self.remove(user:, entry:)
    scope = if entry.movie?
      user.watch_history_entries.where(content_type: :movie, imdb_id: entry.imdb_id)
    else
      user.watch_history_entries.where(content_type: :episode, show_imdb_id: entry.show_imdb_id)
    end

    ServiceResult.success(scope.delete_all)
  rescue StandardError => e
    Rails.logger.error("[WatchHistoryCleanupService] remove failed: #{e.class}: #{e.message}")
    ServiceResult.failure("Unable to remove history")
  end

  def self.clear(user:)
    deleted = ActiveRecord::Base.transaction do
      {
        history: user.watch_history_entries.delete_all,
        episode_progresses: user.episode_progresses.delete_all
      }
    end

    ServiceResult.success(deleted)
  rescue StandardError => e
    Rails.logger.error("[WatchHistoryCleanupService] clear failed: #{e.class}: #{e.message}")
    ServiceResult.failure("Unable to clear history")
  end
end
