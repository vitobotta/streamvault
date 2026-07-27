# frozen_string_literal: true

class CollectionEntry < ApplicationRecord
  enum :content_type, { movie: 0, show: 1 }, validate: true
  enum :list_state, { wishlist: 0, library: 1 }, validate: true

  # Associations
  belongs_to :user

  validates :imdb_id, :title, presence: true
  validates :imdb_id, uniqueness: { scope: :user_id, message: "already in your collection" }
  validates :year, numericality: { greater_than: 1800, less_than: 2100 }, allow_nil: true

  scope :by_type, ->(type) { where(content_type: type) }
  scope :recently_added, -> { order(created_at: :desc) }
  scope :movies, -> { by_type(:movie) }
  scope :shows, -> { by_type(:show) }
end
