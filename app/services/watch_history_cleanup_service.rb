# frozen_string_literal: true

class WatchHistoryCleanupService
  def self.remove(user:, entry:)
    scope = if entry.movie?
      user.playback_progresses.movies_only.where(imdb_id: entry.imdb_id)
    else
      user.playback_progresses.for_show(entry.imdb_id)
    end

    ServiceResult.success(scope.delete_all)
  rescue StandardError => e
    Rails.logger.error("[WatchHistoryCleanupService] remove failed: #{e.class}: #{e.message}")
    ServiceResult.failure("Unable to remove history")
  end

  def self.clear(user:)
    deleted = user.playback_progresses.delete_all

    ServiceResult.success(deleted)
  rescue StandardError => e
    Rails.logger.error("[WatchHistoryCleanupService] clear failed: #{e.class}: #{e.message}")
    ServiceResult.failure("Unable to clear history")
  end
end
