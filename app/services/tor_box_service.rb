# frozen_string_literal: true

# Minimal TorBox client.  Stream resolution goes through the configured
# provider (Torrentio/Comet/AIOStreams), which embeds the TorBox key and
# returns a direct CDN link; this client verifies the key an account or an
# administrator enters.
class TorBoxService
  BASE_URL = ENV.fetch("TORBOX_API_BASE_URL", "https://api.torbox.app/v1/api")

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
    response = @conn.get("user/me")
    return ServiceResult.success(response.body) if response.success? && response.body.is_a?(Hash) && response.body["success"] != false

    ServiceResult.failure(parse_error(response), response.status)
  rescue Faraday::TimeoutError
    ServiceResult.failure("Request timed out")
  rescue Faraday::ConnectionFailed
    ServiceResult.failure("Could not connect to TorBox")
  rescue StandardError => e
    Rails.logger.error("TorBoxService#verify_key error: #{e.class}: #{e.message}")
    ServiceResult.failure("Failed to verify API key")
  end

  private

  def parse_error(response)
    return "Request failed with status #{response.status}" unless response.body.is_a?(Hash)

    # `error` is a machine-readable code; `detail` is the user-facing message
    # (see https://api-docs.torbox.app).  Prefer the readable one.
    response.body["detail"].presence || response.body["error"].presence ||
      "Request failed with status #{response.status}"
  end
end
