# frozen_string_literal: true

class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Encryption
  encrypts :realdebrid_api_key, deterministic: false

  # Associations
  has_many :collection_entries, dependent: :destroy
  has_many :playback_progresses, dependent: :destroy
  has_many :hls_sessions, dependent: :destroy
  has_many :playlists, dependent: :destroy

  # Language preferences
  serialize :preferred_languages, coder: JSON

  STREAM_LANGUAGE_OPTIONS = {
    "ENG" => "English", "FRENCH" => "French", "GERMAN" => "German",
    "SPANISH" => "Spanish", "ITALIAN" => "Italian", "JAPANESE" => "Japanese",
    "KOREAN" => "Korean", "CHINESE" => "Chinese", "HINDI" => "Hindi",
    "ARABIC" => "Arabic", "PORTUGUESE" => "Portuguese", "RUSSIAN" => "Russian",
    "DUTCH" => "Dutch", "POLISH" => "Polish", "TURKISH" => "Turkish",
    "SWEDISH" => "Swedish", "FINNISH" => "Finnish"
  }.freeze

  before_validation :set_default_languages, on: :create
  before_validation :normalize_languages, on: :update
  validate :preferred_languages_present, on: :update
  validate :preferred_languages_must_be_array, on: :update

  validates :display_name, length: { maximum: 50 }

  # Child accounts / parental controls
  CHILD_LOCK_MIN_LENGTH = 4
  MAX_RATING_AGE_RANGE = 0..18
  MAX_RATING_AGE_OPTIONS = [
    [ "0+ - little kids (TV-Y, G)", 0 ],
    [ "7+ - older kids (TV-Y7)", 7 ],
    [ "8+ - (PG, TV-PG)", 8 ],
    [ "13+ - teens (PG-13)", 13 ],
    [ "14+ - (TV-14)", 14 ],
    [ "17+ - older teens (R, TV-MA)", 17 ],
    [ "18+ - everything, including unrated", 18 ]
  ].freeze

  attr_accessor :child_lock_password, :child_lock_password_confirmation, :child_lock_current_password

  before_validation :digest_child_lock_password
  after_save :clear_child_lock_credentials
  validate :validate_child_account_settings

  def child_lock_set?
    child_lock_password_digest.present?
  end

  def valid_child_lock_password?(attempt)
    # Compare against the persisted digest: during validation the
    # in-memory digest may already hold a replacement that has not been
    # saved yet, and the attempt must be checked against the old one.
    digest = child_lock_password_digest
    digest = child_lock_password_digest_was if persisted? && child_lock_password_digest_was.present?
    return false if digest.blank? || attempt.blank?

    Devise::Encryptor.compare(self.class, digest, attempt)
  end

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

  def digest_child_lock_password
    return if child_lock_password.blank?

    self.child_lock_password_digest = Devise::Encryptor.digest(self.class, child_lock_password)
  end

  # The credential accessors are one-shot: drop them after saving so a
  # later save on the same instance does not re-apply a stale value.
  def clear_child_lock_credentials
    self.child_lock_password = nil
    self.child_lock_password_confirmation = nil
    self.child_lock_current_password = nil
  end

  def validate_child_account_settings
    validate_max_rating_age
    validate_child_lock_password
    validate_child_lock_protection
  end

  def validate_max_rating_age
    return unless child_account?

    if max_rating_age.nil?
      errors.add(:max_rating_age, "must be set for child accounts")
    elsif !MAX_RATING_AGE_RANGE.cover?(max_rating_age)
      errors.add(:max_rating_age, "must be between #{MAX_RATING_AGE_RANGE.begin} and #{MAX_RATING_AGE_RANGE.end}")
    end
  end

  def validate_child_lock_password
    return if child_lock_password.blank?

    if child_lock_password.length < CHILD_LOCK_MIN_LENGTH
      errors.add(:child_lock_password, "must be at least #{CHILD_LOCK_MIN_LENGTH} characters")
    end
    if child_lock_password_confirmation.present? && child_lock_password_confirmation != child_lock_password
      errors.add(:child_lock_password_confirmation, "doesn't match")
    end
  end

  def validate_child_lock_protection
    # Enabling child status requires a lock password to exist — either
    # one set previously or one provided with this change.
    if child_account? && child_lock_password.blank? && child_lock_password_digest.blank?
      errors.add(:child_lock_password, "must be set to enable child accounts")
    end

    return unless child_lock_change_requires_password?
    return if valid_child_lock_password?(child_lock_current_password)

    errors.add(:child_lock_current_password, "is incorrect")
  end

  # Turning child status off, changing the max rating age on a child
  # account, and replacing the lock password itself are all protected
  # changes that require the current child lock password.
  def child_lock_change_requires_password?
    return false unless persisted?

    turning_off = child_account_changed? && !child_account?
    changing_age = max_rating_age_changed? && (child_account_was || false)
    changing_password = child_lock_password.present? &&
      child_lock_password_digest_was.present? &&
      !valid_child_lock_password?(child_lock_password)
    turning_off || changing_age || changing_password
  end

  def set_default_languages
    self.preferred_languages ||= [ "ENG" ]
    self.default_language ||= "ENG"
  end

  def normalize_languages
    if preferred_languages.blank?
      self.preferred_languages = [ "ENG" ]
    else
      # Normalize to a flat array of valid uppercase language codes,
      # defaulting to ENG if every selection was invalid.  Extract to a
      # local variable so the data flow is explicit (the old code
      # reassigned self.preferred_languages twice with an implicit
      # ordering dependency between the two assignments).
      normalized = Array(preferred_languages).map(&:to_s).map(&:upcase).uniq.select { |l| STREAM_LANGUAGE_OPTIONS.key?(l) }
      normalized = [ "ENG" ] if normalized.empty?
      self.preferred_languages = normalized
    end
    self.default_language = (default_language.presence || "ENG").upcase
    self.default_language = preferred_languages.first unless preferred_languages.include?(default_language)
  end

  def preferred_languages_present
    errors.add(:preferred_languages, "must include at least one language") if preferred_languages.blank? || Array(preferred_languages).empty?
  end

  # Guard against type confusion: serialize + JSON coder could persist
  # a non-Array if the strong-params permit were ever widened or a
  # factory bypassed normalization.  Array(hash) produces surprising
  # results, so reject it early.
  def preferred_languages_must_be_array
    return if preferred_languages.nil?
    errors.add(:preferred_languages, "must be an array") unless preferred_languages.is_a?(Array)
  end
end
