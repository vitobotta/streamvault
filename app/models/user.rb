# frozen_string_literal: true

class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Encryption
  encrypts :realdebrid_api_key, deterministic: false

  # Associations
  has_many :library_entries, dependent: :destroy
  has_many :watch_history_entries, dependent: :destroy
  has_many :wishlist_entries, dependent: :destroy
  has_many :episode_progresses, dependent: :destroy

  # Validations
  validates :display_name, length: { maximum: 50 }

  # Helpers
  def has_realdebrid_key?
    realdebrid_api_key.present?
  end
end
