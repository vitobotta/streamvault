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
  LANGUAGE_PATTERNS = TorrentioService::LANGUAGE_PATTERNS
  QUALITY_SORT = TorrentioService::QUALITY_SORT

  def self.comet_url
    ENV.fetch("COMET_URL", "")
  end

  def self.comet_proxy
    ENV.fetch("COMET_PROXY", "")
  end

  def initialize(rd_api_key: nil)
    @rd_api_key = rd_api_key
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
      language_priority = normalize_language_priority(default_language, preferred_languages)
      parsed = filter_by_preferred_languages(parsed, language_priority) if language_priority.present?
      parsed = sort_streams(parsed, language_priority: language_priority)
      ServiceResult.success(parsed)
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
    Base64.urlsafe_encode64(JSON.generate(config), padding: false)
  end

  # Parse Comet stream objects into the same normalized hash shape that
  # TorrentioService produces, so ContentStreamingService can consume
  # streams from either provider interchangeably.
  def parse_streams(raw_streams)
    raw_streams.map do |s|
      title_text = s["title"].to_s
      filename = s.dig("behaviorHints", "filename").to_s
      size_bytes = parse_size_bytes(title_text)
      {
        title: s["title"],
        info_hash: s["infoHash"],
        file_idx: s["fileIdx"],
        name: s["name"],
        quality: extract_quality(s["title"] || s["name"]),
        seeders: extract_seeders(s),
        size: size_bytes ? format_size(size_bytes) : "Unknown",
        raw_size: size_bytes || 0,
        rd_plus: s["sources"].is_a?(Array) && s["sources"].any?,
        filename: filename,
        resolve_url: s["url"].to_s,
        languages: extract_languages(title_text)
      }
    end
  end

  def filter_by_preferred_languages(streams, preferred_languages, default_language: nil)
    return streams if preferred_languages.blank?
    langs = normalize_language_list(preferred_languages)

    streams.select do |s|
      (s[:languages] & langs).any? || (s[:languages].empty? && langs.include?("ENG"))
    end
  end

  def sort_streams(streams, language_priority: [])
    streams_with_scores = streams.map do |stream|
      stream.merge(language_score: stream_language_score(stream, language_priority))
    end

    streams_with_scores.sort_by do |s|
      language_score = s[:language_score]
      rd_score = s[:rd_plus] ? 0 : 1
      quality_score = QUALITY_SORT[s[:quality]] || 4
      size_bytes = s[:raw_size].is_a?(Numeric) ? s[:raw_size] : 0
      [ language_score, rd_score, quality_score, -size_bytes ]
    end
  end

  def stream_language_score(stream, language_priority)
    return 0 if language_priority.blank?

    stream_languages = Array(stream[:languages]).map(&:to_s).map(&:upcase)
    # Unmarked streams are assumed English — score them as ENG.
    stream_languages = [ "ENG" ] if stream_languages.empty?
    matching_indexes = stream_languages.filter_map { |language| language_priority.index(language) }
    matching_indexes.min || language_priority.length
  end

  def normalize_language_priority(default_language, preferred_languages)
    normalize_language_list([ default_language ] + Array(preferred_languages))
  end

  def normalize_language_list(languages)
    Array(languages)
      .flatten
      .map(&:to_s)
      .map(&:upcase)
      .select { |language| LANGUAGE_PATTERNS.key?(language) }
      .uniq
  end

  def extract_languages(title)
    return [] if title.blank?
    langs = LANGUAGE_PATTERNS.select { |_, pattern| title.match?(pattern) }.keys
    langs = LANGUAGE_PATTERNS.keys if title.match?(/\bMULTi|MULTIPLE|MULTI\b/i)
    langs
  end

  def parse_size_bytes(title)
    match = title.match(/💾\s*([\d.]+)\s*(GB|MB|KB)/i)
    return nil unless match
    value = match[1].to_f
    case match[2].upcase
    when "GB" then (value * 1_073_741_824).to_i
    when "MB" then (value * 1_048_576).to_i
    when "KB" then (value * 1024).to_i
    end
  end

  def extract_quality(title)
    return "Unknown" unless title
    case title
    when /2160p|4K/i then "4K"
    when /1080p/i then "1080p"
    when /720p/i then "720p"
    when /480p/i then "480p"
    else "Unknown"
    end
  end

  def extract_seeders(stream)
    if stream["seeders"]
      stream["seeders"]
    elsif stream["title"] && stream["title"] =~ /👤\s*(\d+)/
      $1.to_i
    else
      0
    end
  end

  def format_size(bytes)
    return "Unknown" unless bytes.is_a?(Numeric)
    if bytes >= 1_073_741_824
      "#{(bytes / 1_073_741_824.0).round(1)} GB"
    elsif bytes >= 1_048_576
      "#{(bytes / 1_048_576.0).round(1)} MB"
    else
      "#{(bytes / 1024.0).round(1)} KB"
    end
  end
end
