# frozen_string_literal: true

class WishlistEntry < ApplicationRecord
  # Enums
  enum :content_type, { movie: 0, show: 1 }, validate: true

  # Associations
  belongs_to :user

  # Validations
  validates :imdb_id, presence: true
  validates :title, presence: true
  validates :imdb_id, uniqueness: { scope: :user_id, message: "already in your wishlist" }
  validates :year, numericality: { greater_than: 1800, less_than: 2100 }, allow_nil: true

  # Scopes
  scope :by_type, ->(type) { where(content_type: type) }
  scope :recently_added, -> { order(created_at: :desc) }
end
