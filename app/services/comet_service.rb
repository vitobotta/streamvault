# frozen_string_literal: true

require "base64"
require "json"

# Stream provider for self-hosted Comet (https://github.com/g0ldyy/comet).
#
# Comet speaks the standard Stremio addon protocol — /stream/{type}/{id}.json
# returns { "streams": [...] } — but the RealDebrid API key and user
# preferences are encoded in a base64 config path segment instead of the
# /realdebrid={key}/ prefix that Torrentio uses.
#
# Comet's config is a JSON object base64-encoded for the URL:
#   {"debridService":"realdebrid","debridApiKey":"<key>","...":"..."}
# The stream path becomes:
#   /{b64config}/stream/{type}/{id}.json
#
# When no config is needed (no RD key, default options), Comet serves at:
#   /stream/{type}/{id}.json
#
# Resolve URLs in Comet's stream response point to the Comet host's
# /{b64config}/playback/... endpoint, which 302-redirects to the
# RealDebrid direct download URL — same follow-redirect flow as Torrentio.
class CometService
  def self.comet_url
    ENV.fetch("COMET_URL", "")
  end

  def self.comet_proxy
    ENV.fetch("COMET_PROXY", "")
  end

  def initialize(rd_api_key: nil)
    @rd_api_key = rd_api_key
    @parser = Streams::ReleaseParser.new
    @comet = Faraday.new(url: self.class.comet_url) do |f|
      f.request :json
      f.response :json
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
      f.options.timeout = 30
      f.options.open_timeout = 5
      f.proxy = self.class.comet_proxy if self.class.comet_proxy.present?
    end
  end

  def streams(imdb_id, type, season: nil, episode: nil, title: nil, preferred_languages: nil, default_language: nil)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?
    return ServiceResult.failure("Comet URL not configured") if self.class.comet_url.blank?

    path = build_stream_path(imdb_id, type, season: season, episode: episode)
    response = @comet.get(path)

    if response.success? && response.body.is_a?(Hash) && response.body["streams"]
      parsed = parse_streams(response.body["streams"])
      ranked = Streams::Ranker.new(
        default_language: default_language,
        preferred_languages: preferred_languages
      ).call(parsed)
      ServiceResult.success(ranked)
    elsif response.status == 404
      ServiceResult.success([])
    else
      Rails.logger.error("[CometService] streams request failed: HTTP #{response.status} for #{path}")
      ServiceResult.failure("Failed to fetch streams from Comet (HTTP #{response.status})")
    end
  rescue Faraday::TimeoutError
    Rails.logger.error("[CometService] streams request timed out for #{path}")
    ServiceResult.failure("Comet stream request timed out")
  rescue Faraday::ConnectionFailed => e
    Rails.logger.error("[CometService] streams connection failed: #{e.message}")
    ServiceResult.failure("Could not connect to Comet")
  rescue StandardError => e
    Rails.logger.error("[CometService] streams error: #{e.message}")
    ServiceResult.failure("An unexpected error occurred")
  end

  # The base URL for resolve-URL origin validation.  Comet's playback
  # endpoints live on the same host as the stream listing.
  def self.resolve_base_url
    comet_url
  end

  private

  def build_stream_path(imdb_id, type, season: nil, episode: nil)
    config = build_config
    prefix = config ? "/#{config}" : ""

    episode_path = if type.to_s.in?(%w[show series]) && season && episode
      "series/#{imdb_id}:#{season}:#{episode}"
    else
      "movie/#{imdb_id}"
    end

    "#{prefix}/stream/#{episode_path}.json"
  end

  # Build the base64-encoded config path segment.  When the RD key is
  # absent, return nil so Comet serves at the default (no-config) path.
  def build_config
    return nil if @rd_api_key.blank?

    config = {
      "debridService" => "realdebrid",
      "debridApiKey" => @rd_api_key
    }
    # NOTE: Comet requires standard (padded) base64.  Using `padding: false`
    # produces unpadded base64, which Comet's config parser fails to decode —
    # it silently treats the request as having no debrid config and returns a
    # single placeholder stream instead of real results.
    Base64.urlsafe_encode64(JSON.generate(config))
  end

  # Normalize Comet stream objects into StreamCandidate values shared by
  # every provider and the resolver.
  # Comet's Stremio stream objects carry the real metadata in `description`
  # and `behaviorHints`, NOT in top-level `title`/`infoHash`/`sources` (those
  # are Torrentio's shape).  Comet returns:
  #   name        => "[RD⚡] Comet 2160p"  (identical across same-resolution
  #                                        streams — useless as a label)
  #   description => "📄 <release>.mkv\n🎞 ...\n⭐ ...\n💾 50.4 GB 🔎 DMM"
  #   behaviorHints.filename  => the actual release name
  #   behaviorHints.videoSize  => file size in bytes
  #   behaviorHints.bingeGroup => "comet|realdebrid|<sha1_info_hash>"
  def parse_streams(raw_streams)
    raw_streams.map do |stream|
      description = stream["description"].to_s
      behavior_hints = stream["behaviorHints"] || {}
      filename = behavior_hints["filename"].to_s
      title = filename.presence || stream["name"].to_s
      attributes = @parser.analyze(title: title, filename: filename.presence || description)
      size = behavior_hints["videoSize"] || @parser.size_bytes(description) || attributes[:raw_size]
      info_hash = behavior_hints["bingeGroup"].to_s.split("|").last.presence || stream["infoHash"]

      StreamCandidate.new(
        title: title, info_hash: info_hash, file_idx: stream["fileIdx"], name: stream["name"],
        quality: @parser.quality(stream["name"].presence || title),
        seeders: extract_seeders(stream, description), size: @parser.format_size(size), raw_size: size,
        rd_plus: stream["name"].to_s.include?("⚡"), filename: filename,
        resolve_url: stream["url"].to_s, languages: @parser.languages(description),
        video_codec: attributes[:video_codec], audio_codec: attributes[:audio_codec],
        container: attributes[:container], compatibility_score: attributes[:compatibility_score],
        provider: self.class.name
      )
    end
  end

  def extract_seeders(stream, description = nil)
    if stream["seeders"]
      stream["seeders"]
    else
      text = [ stream["title"], description ].compact.join(" ")
      if text =~ /👤\s*(\d+)/
        $1.to_i
      else
        0
      end
    end
  end
end
