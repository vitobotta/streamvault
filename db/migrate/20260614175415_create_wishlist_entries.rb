class CreateWishlistEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :wishlist_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :content_type, null: false, default: 0
      t.string :imdb_id, null: false
      t.string :title, null: false
      t.string :poster_url
      t.integer :year

      t.timestamps
    end

    add_index :wishlist_entries, [:user_id, :imdb_id], unique: true
  end
end
