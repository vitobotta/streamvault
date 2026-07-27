# frozen_string_literal: true

class RealDebridService
  BASE_URL = ENV.fetch("REALDEBRID_API_BASE_URL", "https://api.real-debrid.com/rest/1.0")

  def initialize(api_key)
    @conn = Faraday.new(url: BASE_URL) do |faraday|
      faraday.response :json
      faraday.adapter Faraday.default_adapter
      faraday.options.timeout = 30
      faraday.options.open_timeout = 10
      faraday.headers["Authorization"] = "Bearer #{api_key}"
    end
  end

  def verify_key
    response = @conn.get("user")
    return ServiceResult.success(response.body) if response.success?

    ServiceResult.failure(parse_error(response), response.status)
  rescue Faraday::TimeoutError
    ServiceResult.failure("Request timed out")
  rescue StandardError => e
    Rails.logger.error("RealDebridService#verify_key error: #{e.message}")
    ServiceResult.failure("Failed to verify API key")
  end

  private

  def parse_error(response)
    return "Request failed with status #{response.status}" unless response.body.is_a?(Hash)

    response.body["error"] || "Request failed with status #{response.status}"
  end
end
