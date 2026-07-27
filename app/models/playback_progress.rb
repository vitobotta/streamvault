# frozen_string_literal: true

class PlaybackProgress < ApplicationRecord
  # Enums
  enum :content_type, { movie: 0, episode: 1 }, validate: true

  # Associations
  belongs_to :user

  validates :imdb_id, :title, :watched_at, presence: true
  validates :progress_seconds, :duration_seconds, numericality: { greater_than_or_equal_to: 0 }
  validates :season_number, :episode_number, numericality: { greater_than_or_equal_to: 0 }
  validates :imdb_id, uniqueness: {
    scope: %i[user_id content_type season_number episode_number],
    message: "progress for this title already exists"
  }

  scope :recently_watched, -> { order(watched_at: :desc) }
  scope :for_show, ->(imdb_id) { episodes_only.where(imdb_id: imdb_id) }
  scope :movies_only, -> { where(content_type: :movie) }
  scope :episodes_only, -> { where(content_type: :episode) }

  def progress_percentage
    return progress_seconds.positive? ? 1 : 0 unless duration_seconds.positive?

    ((progress_seconds.to_f / duration_seconds) * 100).round.clamp(0, 100)
  end
end
