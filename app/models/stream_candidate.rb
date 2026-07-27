# frozen_string_literal: true

class StreamCandidate
  ATTRIBUTES = %i[
    title info_hash file_idx name quality seeders size raw_size rd_plus filename
    resolve_url languages video_codec audio_codec container compatibility_score
    language_score provider
  ].freeze

  attr_reader(*ATTRIBUTES)

  def initialize(**attributes)
    unknown = attributes.keys.map(&:to_sym) - ATTRIBUTES
    raise ArgumentError, "unknown stream attributes: #{unknown.join(', ')}" if unknown.any?

    ATTRIBUTES.each { |name| instance_variable_set("@#{name}", attributes[name]) }
    @languages = Array(@languages).map(&:to_s).freeze
    @language_score = @language_score.to_i
    @compatibility_score = @compatibility_score.to_i
    @raw_size = @raw_size.to_i
    freeze
  end

  def self.from(value, provider: nil)
    return value if value.is_a?(self) && provider.nil?

    attributes = value.to_h.symbolize_keys.slice(*ATTRIBUTES)
    attributes[:provider] = provider if provider
    new(**attributes)
  end

  def [](key)
    public_send(key) if ATTRIBUTES.include?(key.to_sym)
  end

  def merge(attributes)
    self.class.new(**to_h.merge(attributes.to_h.symbolize_keys))
  end

  def to_h
    ATTRIBUTES.index_with { |name| public_send(name) }
  end

  def ==(other)
    other.is_a?(StreamCandidate) && other.to_h == to_h
  end
  alias eql? ==

  def hash
    to_h.hash
  end

  def as_json(*)
    to_h
  end
end
