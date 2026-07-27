# frozen_string_literal: true

class PlaybackDescriptor
  PURPOSE = "playback-descriptor"
  TOKEN_TTL = ResolvedSource::TOKEN_TTL

  attr_reader :source_token, :filename, :content_ref, :title, :poster_url,
    :resume_at, :duration, :direct_play_hint

  def initialize(source_token:, filename:, content_ref:, title: nil, poster_url: nil,
    resume_at: nil, duration: nil, direct_play_hint: false)
    @source_token = source_token.to_s
    @filename = filename.to_s
    @content_ref = content_ref.is_a?(ContentRef) ? content_ref : ContentRef.from_h(content_ref)
    @title = title.to_s.presence
    @poster_url = poster_url.to_s.presence
    @resume_at = non_negative_number(resume_at)
    @duration = non_negative_number(duration).to_i
    @direct_play_hint = ActiveModel::Type::Boolean.new.cast(direct_play_hint)
    raise ArgumentError, "source token is required" if @source_token.blank?

    freeze
  end
  def to_token(user:)
    ApplicationToken.issue(token_payload(user), purpose: PURPOSE, expires_in: TOKEN_TTL)
  end


  def self.resolve(token:, user:)
    payload = ApplicationToken.verify(token, purpose: PURPOSE).with_indifferent_access
    raise ApplicationToken::Invalid, "descriptor belongs to another user" unless payload.fetch(:user_id).to_i == user.id

    new(**payload.except(:user_id).symbolize_keys)
  rescue KeyError, ArgumentError
    raise ApplicationToken::Invalid, "invalid playback descriptor"
  end

  def to_h
    {
      source_token: source_token,
      filename: filename,
      content_ref: content_ref.to_h,
      title: title,
      poster_url: poster_url,
      resume_at: resume_at,
      duration: duration,
      direct_play_hint: direct_play_hint
    }
  end

  def token_payload(user)
    to_h.merge(user_id: user.id)
  end

  def self.issue(user:, **attributes)
    descriptor = new(**attributes)
    ApplicationToken.issue(descriptor.token_payload(user), purpose: PURPOSE, expires_in: TOKEN_TTL)
  end

  private

  def non_negative_number(value)
    number = Float(value, exception: false)
    number&.finite? && number.positive? ? number : 0.0
  end
end
