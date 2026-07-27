# frozen_string_literal: true

class ContentRef
  TYPES = %w[movie show].freeze
  IMDB_ID_PATTERN = /\Att\d{7,8}\z/

  attr_reader :imdb_id, :type, :season, :episode

  def initialize(imdb_id:, type:, season: nil, episode: nil)
    @imdb_id = imdb_id.to_s
    @type = type.to_s
    @season = normalize_episode_number(season)
    @episode = normalize_episode_number(episode)
    validate!
    freeze
  end

  def self.from_h(value)
    attributes = value.to_h.with_indifferent_access
    new(
      imdb_id: attributes.fetch(:imdb_id),
      type: attributes.fetch(:type),
      season: attributes[:season],
      episode: attributes[:episode]
    )
  end

  def movie?
    type == "movie"
  end

  def show?
    type == "show"
  end

  def episode?
    show? && season.present? && episode.present?
  end

  def to_h
    { imdb_id: imdb_id, type: type, season: season, episode: episode }
  end

  def ==(other)
    other.is_a?(ContentRef) && other.to_h == to_h
  end
  alias eql? ==

  def hash
    to_h.hash
  end

  private

  def normalize_episode_number(value)
    return if value.blank?

    Integer(value, exception: false)
  end

  def validate!
    raise ArgumentError, "invalid IMDb id" unless imdb_id.match?(IMDB_ID_PATTERN)
    raise ArgumentError, "invalid content type" unless TYPES.include?(type)
    raise ArgumentError, "movies cannot have an episode" if movie? && (season || episode)
    raise ArgumentError, "season and episode must be provided together" if season.nil? != episode.nil?
    raise ArgumentError, "season and episode must be positive" if season && (!season.positive? || !episode.positive?)
  end
end
