# frozen_string_literal: true

class ServiceResult
  attr_reader :data, :error_message, :error_code

  def initialize(success:, data: nil, error_message: nil, error_code: nil)
    @success = success
    @data = data
    @error_message = error_message
    @error_code = error_code
  end

  def success?
    @success
  end

  def failure?
    !@success
  end

  def self.success(data = nil)
    new(success: true, data: data)
  end

  def self.failure(message, code = nil)
    new(success: false, error_message: message, error_code: code)
  end
end
