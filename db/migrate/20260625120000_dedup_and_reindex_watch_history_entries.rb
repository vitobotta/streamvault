# frozen_string_literal: true

# Re-add the unique index on watch_history_entries now that
# ProgressTrackingService#save_progress upserts instead of inserting a
# new row on every 5s save.  First deduplicates existing rows — for
# each (user, content key) keep only the row with the latest watched_at
# (highest id as a tiebreaker), deleting the rest.  The unique key is
# (user_id, imdb_id, content_type, season_number, episode_number):
# for movies show_imdb_id is nil and season/episode are 0; for episodes
# imdb_id holds the show id and distinct episodes differ by
# season/episode number.
class DedupAndReindexWatchHistoryEntries < ActiveRecord::Migration[8.1]
  def up
    # Deduplicate: keep only the latest entry per content key.
    # MAX(id) picks the most-recently-inserted row for each group; since
    # watched_at is updated on every upsert (set to Time.current), the
    # newest row has the freshest progress.  Rows created before the
    # upsert fix (one per 5s save) are collapsed into a single row.
    execute <<~SQL
      DELETE FROM watch_history_entries WHERE id NOT IN (
        SELECT MAX(id) FROM watch_history_entries
        GROUP BY user_id, imdb_id, content_type, season_number, episode_number
      )
    SQL

    add_index :watch_history_entries,
      [ :user_id, :imdb_id, :content_type, :season_number, :episode_number ],
      unique: true,
      name: "idx_watch_history_entries_unique"
  end

  def down
    remove_index :watch_history_entries, name: "idx_watch_history_entries_unique"
  end
end
