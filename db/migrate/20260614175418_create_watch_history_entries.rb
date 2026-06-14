class CreateWatchHistoryEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :watch_history_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :content_type, null: false, default: 0
      t.string :imdb_id, null: false
      t.string :title, null: false
      t.string :poster_url
      t.integer :season_number
      t.integer :episode_number
      t.string :show_imdb_id
      t.string :show_title
      t.datetime :watched_at, null: false
      t.integer :progress_seconds, null: false, default: 0
      t.integer :duration_seconds, null: false, default: 0
      t.integer :progress_percentage, null: false, default: 0

      t.timestamps
    end

    add_index :watch_history_entries, [:user_id, :imdb_id]
    add_index :watch_history_entries, :watched_at
    add_index :watch_history_entries, :show_imdb_id
  end
end
