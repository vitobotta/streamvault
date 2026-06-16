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

  # Language preferences
  serialize :preferred_languages, coder: JSON

  STREAM_LANGUAGE_OPTIONS = {
    "ENG" => "English", "FRENCH" => "French", "GERMAN" => "German",
    "SPANISH" => "Spanish", "ITALIAN" => "Italian", "JAPANESE" => "Japanese",
    "KOREAN" => "Korean", "CHINESE" => "Chinese", "HINDI" => "Hindi",
    "ARABIC" => "Arabic", "PORTUGUESE" => "Portuguese", "RUSSIAN" => "Russian",
    "DUTCH" => "Dutch", "POLISH" => "Polish", "TURKISH" => "Turkish",
    "SWEDISH" => "Swedish"
  }.freeze

  before_validation :normalize_languages

  def has_realdebrid_key?
    realdebrid_api_key.present?
  end

  def preferred_stream_languages
    Array(preferred_languages).presence
  end

  private

  def normalize_languages
    return if preferred_languages.blank?
    self.preferred_languages = Array(preferred_languages).map(&:to_s).map(&:upcase).uniq.select { |l| STREAM_LANGUAGE_OPTIONS.key?(l) }
    self.preferred_languages = nil if preferred_languages.empty?
    self.default_language = default_language&.upcase
  end
end
