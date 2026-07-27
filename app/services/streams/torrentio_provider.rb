# frozen_string_literal: true

module Streams
  class TorrentioProvider
    BASE_URL = ENV.fetch("TORRENTIO_API_BASE_URL", "https://torrentio.strem.fun")

    def initialize(rd_api_key: nil, connection: nil, parser: ReleaseParser.new, logger: Rails.logger)
      @rd_api_key = rd_api_key
      @parser = parser
      @logger = logger
      @connection = connection || Faraday.new(url: BASE_URL) do |faraday|
        faraday.request :json
        faraday.response :json
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = 15
        faraday.options.open_timeout = 5
        faraday.proxy = ENV["TORRENTIO_PROXY"] if ENV["TORRENTIO_PROXY"].present?
      end
    end

    def streams(imdb_id, type, season: nil, episode: nil, title: nil, preferred_languages: nil, default_language: nil)
      return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

      path = stream_path(imdb_id, type, season: season, episode: episode)
      response = @connection.get(path)
      if response.success? && response.body.is_a?(Hash) && response.body["streams"]
        candidates = Array(response.body["streams"]).map { |stream| parse(stream) }
        ranked = Ranker.new(
          default_language: default_language,
          preferred_languages: preferred_languages
        ).call(candidates)
        ServiceResult.success(ranked)
      elsif response.status == 404
        ServiceResult.success([])
      else
        @logger.error("[Streams::TorrentioProvider] HTTP #{response.status} for #{redacted(path)}")
        ServiceResult.failure("Failed to fetch streams (HTTP #{response.status})")
      end
    rescue Faraday::TimeoutError
      ServiceResult.failure("Stream request timed out")
    rescue Faraday::ConnectionFailed
      ServiceResult.failure("Could not connect to stream service")
    rescue StandardError => e
      @logger.error("[Streams::TorrentioProvider] #{e.class}: #{e.message}")
      ServiceResult.failure("An unexpected error occurred")
    end

    private

    def stream_path(imdb_id, type, season:, episode:)
      prefix = @rd_api_key.present? ? "/realdebrid=#{@rd_api_key}" : ""
      content = if type.to_s.in?(%w[show series]) && season && episode
        "series/#{imdb_id}:#{season}:#{episode}"
      else
        "movie/#{imdb_id}"
      end
      "#{prefix}/stream/#{content}.json"
    end

    def parse(stream)
      title = stream["title"].to_s
      filename = stream.dig("behaviorHints", "filename").to_s
      attributes = @parser.analyze(title: title, filename: filename)
      size = attributes.fetch(:raw_size)
      StreamCandidate.new(
        title: stream["title"], info_hash: stream["infoHash"], file_idx: stream["fileIdx"],
        name: stream["name"], quality: attributes[:quality], seeders: seeders(stream),
        size: @parser.format_size(size), raw_size: size,
        rd_plus: stream["sources"].is_a?(Array) && stream["sources"].any?,
        filename: filename, resolve_url: rewritten_resolve_url(stream["url"]),
        languages: attributes[:languages], video_codec: attributes[:video_codec],
        audio_codec: attributes[:audio_codec], container: attributes[:container],
        compatibility_score: attributes[:compatibility_score], provider: self.class.name
      )
    end

    def seeders(stream)
      stream["seeders"] || stream["title"].to_s[/👤\s*(\d+)/, 1].to_i
    end

    def rewritten_resolve_url(url)
      return url if url.blank? || BASE_URL == "https://torrentio.strem.fun"

      url.sub("https://torrentio.strem.fun", BASE_URL)
    end

    def redacted(path)
      @rd_api_key.present? ? path.to_s.gsub(@rd_api_key, "[REDACTED]") : path
    end
  end
end
