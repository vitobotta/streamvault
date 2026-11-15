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

  before_validation :normalize_year
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

  # Cinemeta reports a series year as a range ("2008–2013"), and numericality
  # validates the value before it is cast to an integer, so the range rejects
  # the whole row. Accept a single four-digit year or a range of two and keep
  # the first; anything else is left alone for numericality to reject.
  YEAR_PATTERN = /\A(\d{4})(?:\s*[–—-]\s*\d{4})?\z/

  def normalize_year
    raw = read_attribute_before_type_cast(:year)
    return if raw.nil? || raw.is_a?(Integer)

    match = raw.to_s.strip.match(YEAR_PATTERN)
    self.year = match[1] if match
  end

  def assign_position
    self.position = (playlist.playlist_items.maximum(:position) || -1) + 1
  end
end
