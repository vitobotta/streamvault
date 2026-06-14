class CreateEpisodeProgresses < ActiveRecord::Migration[8.1]
  def change
    create_table :episode_progresses do |t|
      t.references :user, null: false, foreign_key: true
      t.string :show_imdb_id, null: false
      t.string :show_title, null: false
      t.integer :season_number, null: false
      t.integer :episode_number, null: false
      t.integer :progress_seconds, null: false, default: 0
      t.integer :duration_seconds, null: false, default: 0
      t.datetime :last_watched_at, null: false

      t.timestamps
    end

    add_index :episode_progresses, [:user_id, :show_imdb_id, :season_number, :episode_number], unique: true, name: "idx_episode_progresses_unique"
    add_index :episode_progresses, [:user_id, :show_imdb_id]
  end
end
