# frozen_string_literal: true

class PlaylistItem < ApplicationRecord
  belongs_to :playlist, touch: true

  enum :content_type, { movie: 0, show: 1 }, validate: true

  validates :imdb_id, :title, presence: true
  validates :imdb_id, uniqueness: {
    scope: %i[playlist_id content_type],
    message: "is already in this playlist"
  }
  validates :year, numericality: { greater_than: 1800, less_than: 2100 }, allow_nil: true

  before_create :assign_position

  scope :ordered, -> { order(position: :asc, id: :asc) }

  # Swaps positions with the adjacent item.  Returns false at either end so a
  # controller can leave the playlist untouched.
  def move!(direction)
    siblings = playlist.playlist_items.ordered.to_a
    index = siblings.index { |item| item.id == id }
    return false unless index

    target = direction.to_s == "up" ? index - 1 : index + 1
    return false unless target.between?(0, siblings.length - 1)

    other = siblings[target]
    self.class.transaction do
      own_position = position
      update_columns(position: other.position, updated_at: Time.current)
      other.update_columns(position: own_position, updated_at: Time.current)
    end
    true
  end

  private

  def assign_position
    self.position = (playlist.playlist_items.maximum(:position) || -1) + 1
  end
end
