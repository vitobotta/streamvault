# frozen_string_literal: true

class CreatePlaylists < ActiveRecord::Migration[8.1]
  def change
    create_table :playlists do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description

      t.timestamps
    end
    add_index :playlists, [ :user_id, :name ], unique: true

    create_table :playlist_items do |t|
      t.references :playlist, null: false, foreign_key: { on_delete: :cascade }
      t.string :imdb_id, null: false
      t.integer :content_type, null: false, default: 0
      t.string :title, null: false
      t.string :poster_url
      t.integer :year
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :playlist_items, [ :playlist_id, :imdb_id, :content_type ], unique: true,
      name: "idx_playlist_items_unique"
    add_index :playlist_items, [ :playlist_id, :position ], name: "idx_playlist_items_order"
  end
end
