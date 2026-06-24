# frozen_string_literal: true

# Remove the unique index on watch_history_entries that enforced one-row-per-
# content. ProgressTrackingService now writes a new row for each progress save
# (every 5 seconds during a watch session), producing multiple entries per
# content. WatchHistoryController#destroy removes all entries for the same
# content (movie) or show (episodes) in a single request.
class RemoveUniqueIndexFromWatchHistoryEntries < ActiveRecord::Migration[8.1]
  def up
    remove_index :watch_history_entries, name: "idx_watch_history_entries_unique"
  end

  def down
    # Re-adding the index requires deduplication first; see the original
    # AddUniqueIndexToWatchHistoryEntries migration for the full procedure.
    add_index :watch_history_entries,
      [ :user_id, :imdb_id, :content_type, :season_number, :episode_number ],
      unique: true,
      name: "idx_watch_history_entries_unique"
  end
end
