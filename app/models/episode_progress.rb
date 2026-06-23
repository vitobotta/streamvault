# frozen_string_literal: true

class EpisodeProgress < ApplicationRecord
  # Associations
  belongs_to :user

  # Validations
  validates :show_imdb_id, presence: true
  validates :show_title, presence: true
  validates :season_number, presence: true, numericality: { greater_than: 0 }
  validates :episode_number, presence: true, numericality: { greater_than: 0 }
  validates :progress_seconds, numericality: { greater_than_or_equal_to: 0 }
  validates :duration_seconds, numericality: { greater_than_or_equal_to: 0 }
  validates :last_watched_at, presence: true
  validates :show_imdb_id, uniqueness: {
    scope: [ :user_id, :season_number, :episode_number ],
    message: "progress for this episode already exists"
  }

  # Scopes
  scope :for_show, ->(imdb_id) { where(show_imdb_id: imdb_id) }
  scope :recently_watched, -> { order(last_watched_at: :desc) }
  scope :by_season, ->(season) { where(season_number: season) }

  # Helpers
  def progress_percentage
    return 0 if duration_seconds.zero?
    ((progress_seconds.to_f / duration_seconds) * 100).round
  end

  def finished?
    progress_percentage >= 95
  end
end
