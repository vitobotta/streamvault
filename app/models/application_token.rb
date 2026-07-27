# frozen_string_literal: true

class ApplicationToken
  class Invalid < StandardError; end

  class << self
    def issue(payload, purpose:, expires_in:)
      encryptor_for(purpose).encrypt_and_sign(payload, expires_in: expires_in, purpose: purpose)
    end

    def verify(token, purpose:)
      payload = encryptor_for(purpose).decrypt_and_verify(token.to_s, purpose: purpose)
      raise Invalid, "invalid or expired token" if payload.nil?

      payload
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      raise Invalid, "invalid or expired token"
    end

    private

    def encryptor_for(purpose)
      @encryptors ||= {}
      @encryptors[purpose] ||= begin
        key = Rails.application.key_generator.generate_key(purpose, ActiveSupport::MessageEncryptor.key_len)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end
  end
end
