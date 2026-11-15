# frozen_string_literal: true

class Playlist < ApplicationRecord
  belongs_to :user

  has_many :playlist_items,
    -> { order(position: :asc, id: :asc) },
    dependent: :destroy,
    inverse_of: :playlist

  validates :name, presence: true, length: { maximum: 80 }
  validates :name, uniqueness: { scope: :user_id, case_sensitive: false }

  before_validation :normalize_name

  def item_count
    playlist_items.size
  end

  private

  def normalize_name
    self.name = name.to_s.squish.presence
  end
end
