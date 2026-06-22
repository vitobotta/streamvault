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

  before_validation :set_default_languages, on: :create
  before_validation :normalize_languages, on: :update
  validate :preferred_languages_present, on: :update

  def has_realdebrid_key?
    realdebrid_api_key.present?
  end

  def preferred_stream_languages
    Array(preferred_languages).presence || [ "ENG" ]
  end

  def default_stream_language
    default_language.presence || preferred_stream_languages.first || "ENG"
  end

  def stream_language_priority
    ([ default_stream_language ] + preferred_stream_languages)
      .map(&:to_s)
      .map(&:upcase)
      .uniq
  end

  private

  def set_default_languages
    self.preferred_languages ||= [ "ENG" ]
    self.default_language ||= "ENG"
  end

  def normalize_languages
    if preferred_languages.blank?
      self.preferred_languages = [ "ENG" ]
    else
      self.preferred_languages = Array(preferred_languages).map(&:to_s).map(&:upcase).uniq.select { |l| STREAM_LANGUAGE_OPTIONS.key?(l) }
      self.preferred_languages = [ "ENG" ] if preferred_languages.empty?
    end
    self.default_language = (default_language.presence || "ENG").upcase
    self.default_language = preferred_languages.first unless preferred_languages.include?(default_language)
  end

  def preferred_languages_present
    errors.add(:preferred_languages, "must include at least one language") if preferred_languages.blank? || Array(preferred_languages).empty?
  end
end
