# frozen_string_literal: true

class AddUniqueIndexToWatchHistoryEntries < ActiveRecord::Migration[8.1]
  def up
    # Backfill NULL season/episode to 0 so we can use a standard unique index
    execute "UPDATE watch_history_entries SET season_number = 0 WHERE season_number IS NULL"
    execute "UPDATE watch_history_entries SET episode_number = 0 WHERE episode_number IS NULL"

    # Deduplicate: keep only the latest entry per content key
    execute <<~SQL
      DELETE FROM watch_history_entries WHERE id NOT IN (
        SELECT MAX(id) FROM watch_history_entries
        GROUP BY user_id, imdb_id, content_type, season_number, episode_number
      )
    SQL

    # Change columns to non-nullable with default 0
    change_column :watch_history_entries, :season_number, :integer, null: false, default: 0
    change_column :watch_history_entries, :episode_number, :integer, null: false, default: 0

    add_index :watch_history_entries,
      [ :user_id, :imdb_id, :content_type, :season_number, :episode_number ],
      unique: true,
      name: "idx_watch_history_entries_unique"
  end

  def down
    remove_index :watch_history_entries, name: "idx_watch_history_entries_unique"
    change_column :watch_history_entries, :season_number, :integer, null: true, default: nil
    change_column :watch_history_entries, :episode_number, :integer, null: true, default: nil
  end
end
