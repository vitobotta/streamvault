class CreateLibraryEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :library_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :content_type, null: false, default: 0
      t.string :imdb_id, null: false
      t.string :title, null: false
      t.string :poster_url
      t.integer :year
      t.integer :watch_status, null: false, default: 0
      t.integer :current_season
      t.integer :current_episode

      t.timestamps
    end

    add_index :library_entries, [:user_id, :imdb_id], unique: true
    add_index :library_entries, :content_type
    add_index :library_entries, :watch_status
  end
end
