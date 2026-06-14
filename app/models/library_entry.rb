# frozen_string_literal: true

class LibraryEntry < ApplicationRecord
  # Enums
  enum :content_type, { movie: 0, show: 1 }, validate: true
  enum :watch_status, { not_started: 0, watching: 1, finished: 2 }, validate: true

  # Associations
  belongs_to :user

  # Validations
  validates :imdb_id, presence: true
  validates :title, presence: true
  validates :imdb_id, uniqueness: { scope: :user_id, message: "already in your library" }
  validates :current_season, numericality: { greater_than: 0 }, allow_nil: true
  validates :current_episode, numericality: { greater_than: 0 }, allow_nil: true
  validates :year, numericality: { greater_than: 1800, less_than: 2100 }, allow_nil: true

  # Scopes
  scope :by_type, ->(type) { where(content_type: type) }
  scope :by_status, ->(status) { where(watch_status: status) }
  scope :recently_added, -> { order(created_at: :desc) }
  scope :movies, -> { by_type(:movie) }
  scope :shows, -> { by_type(:show) }
  scope :currently_watching, -> { by_status(:watching) }
end
