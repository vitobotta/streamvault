# frozen_string_literal: true

class WatchHistoryEntry < ApplicationRecord
  # Enums
  enum :content_type, { movie: 0, episode: 1 }, validate: true

  # Associations
  belongs_to :user

  # Validations
  validates :imdb_id, presence: true
  validates :imdb_id, uniqueness: {
    scope: [:user_id, :content_type, :season_number, :episode_number],
    message: "progress for this content already exists"
  }
  validates :title, presence: true
  validates :watched_at, presence: true
  validates :progress_seconds, numericality: { greater_than_or_equal_to: 0 }
  validates :duration_seconds, numericality: { greater_than_or_equal_to: 0 }
  validates :progress_percentage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  # Scopes
  scope :recently_watched, -> { order(watched_at: :desc) }
  scope :for_show, ->(imdb_id) { where(show_imdb_id: imdb_id) }
  scope :movies_only, -> { where(content_type: :movie) }
  scope :episodes_only, -> { where(content_type: :episode) }
end
