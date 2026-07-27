# frozen_string_literal: true

class ConsolidatePlaybackProgresses < ActiveRecord::Migration[8.1]
  def up
    rename_table :watch_history_entries, :playback_progresses

    remove_index :playback_progresses,
      column: %i[user_id imdb_id content_type season_number episode_number],
      if_exists: true
    remove_index :playback_progresses, column: %i[user_id imdb_id], if_exists: true
    remove_index :playback_progresses, column: :show_imdb_id, if_exists: true
    remove_index :playback_progresses, column: :watched_at, if_exists: true

    execute <<~SQL.squish
      INSERT INTO playback_progresses
        (user_id, imdb_id, content_type, season_number, episode_number, title, poster_url,
         progress_seconds, duration_seconds, watched_at, created_at, updated_at,
         show_imdb_id, show_title, progress_percentage)
      SELECT
        ep.user_id, ep.show_imdb_id, 1, ep.season_number, ep.episode_number, ep.show_title, NULL,
        ep.progress_seconds, ep.duration_seconds, ep.last_watched_at, ep.created_at, ep.updated_at,
        ep.show_imdb_id, ep.show_title,
        CASE WHEN ep.duration_seconds <= 0 THEN 0
          WHEN ep.progress_seconds >= ep.duration_seconds THEN 100
          ELSE ROUND(ep.progress_seconds * 100.0 / ep.duration_seconds) END
      FROM episode_progresses ep
      WHERE NOT EXISTS (
        SELECT 1 FROM playback_progresses pp
        WHERE pp.user_id = ep.user_id
          AND pp.imdb_id = ep.show_imdb_id
          AND pp.content_type = 1
          AND pp.season_number = ep.season_number
          AND pp.episode_number = ep.episode_number
      )
    SQL

    remove_column :playback_progresses, :show_imdb_id, :string
    remove_column :playback_progresses, :show_title, :string
    remove_column :playback_progresses, :progress_percentage, :integer

    add_index :playback_progresses,
      %i[user_id imdb_id content_type season_number episode_number],
      unique: true,
      name: :idx_playback_progresses_unique
    add_index :playback_progresses, %i[user_id imdb_id], name: :idx_playback_progresses_content
    add_index :playback_progresses, :watched_at

    drop_table :episode_progresses
  end

  def down
    create_table :episode_progresses do |table|
      table.references :user, null: false, foreign_key: true
      table.string :show_imdb_id, null: false
      table.string :show_title, null: false
      table.integer :season_number, null: false
      table.integer :episode_number, null: false
      table.integer :progress_seconds, default: 0, null: false
      table.integer :duration_seconds, default: 0, null: false
      table.datetime :last_watched_at, null: false
      table.timestamps
    end
    add_index :episode_progresses, %i[user_id show_imdb_id season_number episode_number], unique: true,
      name: :idx_episode_progresses_unique

    execute <<~SQL.squish
      INSERT INTO episode_progresses
        (user_id, show_imdb_id, show_title, season_number, episode_number,
         progress_seconds, duration_seconds, last_watched_at, created_at, updated_at)
      SELECT
        user_id, imdb_id, title, season_number, episode_number,
        progress_seconds, duration_seconds, watched_at, created_at, updated_at
      FROM playback_progresses
      WHERE content_type = 1
    SQL

    add_column :playback_progresses, :show_imdb_id, :string
    add_column :playback_progresses, :show_title, :string
    add_column :playback_progresses, :progress_percentage, :integer, default: 0, null: false
    execute <<~SQL.squish
      UPDATE playback_progresses
      SET show_imdb_id = imdb_id,
          show_title = title,
          progress_percentage = CASE WHEN duration_seconds <= 0 THEN 0
            WHEN progress_seconds >= duration_seconds THEN 100
            ELSE ROUND(progress_seconds * 100.0 / duration_seconds) END
      WHERE content_type = 1
    SQL

    remove_index :playback_progresses, name: :idx_playback_progresses_unique
    remove_index :playback_progresses, name: :idx_playback_progresses_content
    remove_index :playback_progresses, :watched_at
    rename_table :playback_progresses, :watch_history_entries
    add_index :watch_history_entries,
      %i[user_id imdb_id content_type season_number episode_number],
      unique: true,
      name: :idx_watch_history_entries_unique
    add_index :watch_history_entries, %i[user_id imdb_id], name: :index_watch_history_entries_on_user_id_and_imdb_id
    add_index :watch_history_entries, :show_imdb_id
    add_index :watch_history_entries, :watched_at
  end
end
