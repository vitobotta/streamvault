# frozen_string_literal: true

# Stream provider for AIOStreams (https://github.com/Viren070/AIOStreams).
#
# AIOStreams is a Stremio addon aggregator: an operator configures the
# sources and debrid services once and installs the generated addon URL.
# The install link is the manifest URL, for example:
#
#   https://aiostreams.example.com/stremio/<uuid>/manifest.json
#
# Set AIOSTREAMS_URL to that install link (or its base without
# /manifest.json).  Streams are requested at:
#
#   <base>/stream/{movie|series}/{imdb_id}.json
#
# AIOStreams may proxy playback through its own host or redirect to the
# configured debrid CDN; both are accepted by the resolver as long as the
# returned link is HTTPS and comes from the AIOStreams host or a trusted
# source host.
module Streams
  class AioStreamsProvider
    REQUEST_TIMEOUT = 30
    OPEN_TIMEOUT = 5

    def self.base_url
      raw = ENV.fetch("AIOSTREAMS_URL", "").to_s.strip
      return "" if raw.blank?

      # Strip trailing slashes first so a pasted install link that ends in
      # "/manifest.json/" normalises too; otherwise the manifest suffix
      # survives and every stream request below it 404s.
      raw.sub(%r{/+\z}, "").sub(%r{/+manifest\.json\z}, "")
    end

    def self.configured?
      base_url.present?
    end

    def self.proxy_url
      ENV.fetch("AIOSTREAMS_PROXY", "")
    end

    def initialize(connection: nil, parser: ReleaseParser.new, logger: Rails.logger)
      @parser = parser
      @logger = logger
      @connection = connection || Faraday.new(url: self.class.base_url) do |faraday|
        faraday.request :json
        faraday.response :json
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = REQUEST_TIMEOUT
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.proxy = self.class.proxy_url if self.class.proxy_url.present?
      end
    end

    def streams(imdb_id, type, season: nil, episode: nil, title: nil, preferred_languages: nil, default_language: nil)
      return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?
      return ServiceResult.failure("AIOStreams URL not configured") unless self.class.configured?

      path = stream_path(imdb_id, type, season: season, episode: episode)
      return ServiceResult.failure("Season and episode are required for a series") if path.nil?

      response = @connection.get(path)

      if response.success? && response.body.is_a?(Hash) && response.body["streams"]
        candidates = Array(response.body["streams"]).filter_map { |stream| parse(stream) }
        ranked = Ranker.new(
          default_language: default_language,
          preferred_languages: preferred_languages
        ).call(candidates)
        ServiceResult.success(ranked)
      elsif response.status == 404
        ServiceResult.success([])
      else
        @logger.error("[Streams::AioStreamsProvider] HTTP #{response.status}")
        ServiceResult.failure("Failed to fetch streams from AIOStreams (HTTP #{response.status})")
      end
    rescue Faraday::TimeoutError
      ServiceResult.failure("AIOStreams stream request timed out")
    rescue Faraday::ConnectionFailed
      ServiceResult.failure("Could not connect to AIOStreams")
    rescue StandardError => e
      @logger.error("[Streams::AioStreamsProvider] #{e.class}: #{e.message}")
      ServiceResult.failure("An unexpected error occurred")
    end

    private

    def stream_path(imdb_id, type, season:, episode:)
      if type.to_s.in?(%w[show series])
        # A series request without coordinates must not silently become a
        # movie request for the same IMDb ID.
        return nil if season.blank? || episode.blank?

        return "stream/series/#{imdb_id}:#{season}:#{episode}.json"
      end

      "stream/movie/#{imdb_id}.json"
    end

    def parse(stream)
      return nil unless stream.is_a?(Hash)

      url = stream["url"].to_s
      return nil if url.blank?

      name = stream["name"].to_s
      description = stream["description"].to_s
      hints = stream["behaviorHints"] || {}
      filename = hints["filename"].to_s
      title = filename.presence || name.presence || description
      attributes = @parser.analyze(title: title, filename: filename.presence || description)
      size = hints["videoSize"] || @parser.size_bytes(description) || attributes[:raw_size]
      info_hash = hints["bingeGroup"].to_s.split("|").last.presence || stream["infoHash"]

      StreamCandidate.new(
        title: title,
        info_hash: info_hash,
        file_idx: stream["fileIdx"],
        name: name,
        quality: @parser.quality(name.presence || title),
        seeders: stream["seeders"].to_i,
        size: @parser.format_size(size),
        raw_size: size,
        rd_plus: name.include?("⚡") || description.include?("⚡"),
        filename: filename,
        resolve_url: url,
        languages: @parser.languages(description.presence || title),
        video_codec: attributes[:video_codec],
        audio_codec: attributes[:audio_codec],
        container: attributes[:container],
        compatibility_score: attributes[:compatibility_score],
        provider: self.class.name
      )
    end
  end
end
