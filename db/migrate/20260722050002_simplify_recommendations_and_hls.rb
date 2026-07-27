# frozen_string_literal: true

class SimplifyRecommendationsAndHls < ActiveRecord::Migration[8.1]
  def change
    drop_table :recommendations do |table|
      table.references :user, null: false, foreign_key: true
      table.integer :tmdb_id, null: false
      table.string :imdb_id, null: false
      table.string :title
      table.string :poster_url
      table.string :content_type
      table.string :year
      table.integer :position, default: 0, null: false
      table.timestamps

      table.index %i[user_id tmdb_id], unique: true
      table.index %i[user_id position]
    end

    add_column :hls_sessions, :error_message, :text
  end
end
