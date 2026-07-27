# frozen_string_literal: true

class ConsolidateCollectionEntries < ActiveRecord::Migration[8.1]
  def up
    rename_table :library_entries, :collection_entries
    remove_index :collection_entries, column: %i[user_id imdb_id], if_exists: true
    remove_index :collection_entries, column: :watch_status, if_exists: true

    add_column :collection_entries, :list_state, :integer, default: 1, null: false

    execute <<~SQL.squish
      INSERT INTO collection_entries
        (user_id, imdb_id, content_type, title, poster_url, year, list_state, created_at, updated_at,
         watch_status, current_season, current_episode)
      SELECT
        wishlist.user_id, wishlist.imdb_id, wishlist.content_type, wishlist.title,
        wishlist.poster_url, wishlist.year, 0, wishlist.created_at, wishlist.updated_at,
        0, NULL, NULL
      FROM wishlist_entries wishlist
      WHERE NOT EXISTS (
        SELECT 1 FROM collection_entries collection
        WHERE collection.user_id = wishlist.user_id AND collection.imdb_id = wishlist.imdb_id
      )
    SQL

    remove_column :collection_entries, :watch_status, :integer
    remove_column :collection_entries, :current_season, :integer
    remove_column :collection_entries, :current_episode, :integer

    add_index :collection_entries, %i[user_id imdb_id], unique: true, name: :idx_collection_entries_unique
    add_index :collection_entries, %i[user_id list_state], name: :idx_collection_entries_state
    drop_table :wishlist_entries
  end

  def down
    create_table :wishlist_entries do |table|
      table.references :user, null: false, foreign_key: true
      table.integer :content_type, default: 0, null: false
      table.string :imdb_id, null: false
      table.string :title, null: false
      table.string :poster_url
      table.integer :year
      table.timestamps
    end
    add_index :wishlist_entries, %i[user_id imdb_id], unique: true

    execute <<~SQL.squish
      INSERT INTO wishlist_entries
        (user_id, imdb_id, content_type, title, poster_url, year, created_at, updated_at)
      SELECT user_id, imdb_id, content_type, title, poster_url, year, created_at, updated_at
      FROM collection_entries
      WHERE list_state = 0
    SQL

    add_column :collection_entries, :watch_status, :integer, default: 0, null: false
    add_column :collection_entries, :current_season, :integer
    add_column :collection_entries, :current_episode, :integer
    remove_index :collection_entries, name: :idx_collection_entries_unique
    remove_index :collection_entries, name: :idx_collection_entries_state
    remove_column :collection_entries, :list_state, :integer
    rename_table :collection_entries, :library_entries
    add_index :library_entries, %i[user_id imdb_id], unique: true
    add_index :library_entries, :watch_status
  end
end
