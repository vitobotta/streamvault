# frozen_string_literal: true

class MediaProfile
  ATTRIBUTES = %i[
    audio subtitles video_codec video_codec_tag video_width video_height video_pix_fmt
    direct_playable remux_direct_playable
  ].freeze

  attr_reader(*ATTRIBUTES)

  def initialize(**attributes)
    unknown = attributes.keys.map(&:to_sym) - ATTRIBUTES
    raise ArgumentError, "unknown media profile attributes: #{unknown.join(', ')}" if unknown.any?

    ATTRIBUTES.each { |name| instance_variable_set("@#{name}", attributes[name]) }
    @audio = Array(@audio).freeze
    @subtitles = Array(@subtitles).freeze
    @video_codec = @video_codec.to_s
    @video_codec_tag = @video_codec_tag.to_s
    @direct_playable = @direct_playable == true
    @remux_direct_playable = @remux_direct_playable == true
    freeze
  end

  def [](key)
    public_send(key) if ATTRIBUTES.include?(key.to_sym)
  end

  def merge(attributes)
    to_h.merge(attributes)
  end

  def to_h
    ATTRIBUTES.index_with { |name| public_send(name) }
  end

  def as_json(*)
    to_h
  end
end
