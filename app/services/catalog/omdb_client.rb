# frozen_string_literal: true

module Catalog
  class OmdbClient
    def initialize(api_key: ENV.fetch("OMDB_API_KEY", ""), connection: nil, logger: Rails.logger)
      @api_key = api_key
      @logger = logger
      @connection = connection || Faraday.new(url: "https://www.omdbapi.com") do |faraday|
        faraday.response :json
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = 5
        faraday.options.open_timeout = 3
      end
    end

    def ratings(imdb_id)
      return {} if @api_key.blank? || @api_key == "your_omdb_api_key_here"

      data = @connection.get("", { i: imdb_id, apikey: @api_key, tomatoes: "true" }).body
      return {} unless data.is_a?(Hash) && data["Response"] == "True"

      ratings = data["Ratings"].is_a?(Array) ? data["Ratings"].select { |rating| rating.is_a?(Hash) } : []
      rotten_tomatoes = ratings.find { |rating| rating["Source"] == "Rotten Tomatoes" }
      {
        rated: data["Rated"] != "N/A" ? data["Rated"] : nil,
        rt_rating: rotten_tomatoes&.fetch("Value", nil),
        metascore: data["Metascore"] != "N/A" ? data["Metascore"] : nil
      }
    rescue StandardError => e
      @logger.warn("[Catalog::OmdbClient] ratings failed: #{e.class}: #{e.message}")
      {}
    end
  end
end
