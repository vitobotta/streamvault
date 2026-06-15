# frozen_string_literal: true

class TorrentioService
  TORRENTIO_URL = ENV.fetch("TORRENTIO_API_BASE_URL", "https://torrentio.strem.fun")
  CINEMETA_URL = "https://v3-cinemeta.strem.io"
  QUALITY_SORT = { "4K" => 0, "1080p" => 1, "720p" => 2, "480p" => 3, "Unknown" => 4 }.freeze

  def initialize(rd_api_key: nil)
    @rd_api_key = rd_api_key

    @torrentio = Faraday.new(url: TORRENTIO_URL) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 15
      f.options.open_timeout = 5
    end

    @cinemeta = Faraday.new(url: CINEMETA_URL) do |f|
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 10
      f.options.open_timeout = 5
    end
  end

  def search(query)
    return ServiceResult.failure("Query cannot be blank") if query.blank?

    encoded = URI.encode_www_form_component(query)
    results = []

    %w[movie series].each do |type|
      response = @cinemeta.get("catalog/#{type}/top/search=#{encoded}.json")
      next unless response.success? && response.body.is_a?(Hash)
      (response.body["metas"] || []).each { |meta| results << normalize_cinemeta(meta, type) }
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    end

    ServiceResult.success(results)
  rescue StandardError => e
    Rails.logger.error("TorrentioService#search error: #{e.message}")
    ServiceResult.failure("Search failed")
  end

  def streams(imdb_id, type, season: nil, episode: nil, title: nil)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

    path = build_stream_path(imdb_id, type, season: season, episode: episode)
    response = @torrentio.get(path)

    if response.success? && response.body.is_a?(Hash) && response.body["streams"]
      parsed = parse_streams(response.body["streams"])
      parsed = sort_streams(parsed)
      ServiceResult.success(parsed)
    elsif response.status == 404
      ServiceResult.success([])
    else
      ServiceResult.failure("Failed to fetch streams", response.status)
    end
  rescue Faraday::TimeoutError
    ServiceResult.failure("Stream request timed out")
  rescue Faraday::ConnectionFailed
    ServiceResult.failure("Could not connect to stream service")
  rescue StandardError => e
    Rails.logger.error("TorrentioService#streams error: #{e.message}")
    ServiceResult.failure("An unexpected error occurred")
  end

  def metadata(imdb_id, type)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

    cinemeta_type = type.to_s == "show" ? "series" : type.to_s
    response = @cinemeta.get("meta/#{cinemeta_type}/#{imdb_id}.json")

    if response.success? && response.body.is_a?(Hash) && response.body["meta"]
      ServiceResult.success(normalize_cinemeta_meta(response.body["meta"], type))
    else
      ServiceResult.failure("Metadata not found")
    end
  rescue StandardError => e
    Rails.logger.error("TorrentioService#metadata error: #{e.message}")
    ServiceResult.failure("Failed to fetch metadata")
  end

  private

  # Stremio sorting with debrid: RD+ first, quality descending, size descending
  def sort_streams(streams)
    streams.sort_by do |s|
      rd_score = s[:rd_plus] ? 0 : 1
      quality_score = QUALITY_SORT[s[:quality]] || 4
      size_bytes = s[:raw_size].is_a?(Numeric) ? s[:raw_size] : 0
      [rd_score, quality_score, -size_bytes]
    end
  end

  # Build Torrentio URL — same format as Stremio
  # With RD key: torrentio.strem.fun/realdebrid={key}/stream/...
  # Without:     torrentio.strem.fun/stream/...
  def build_stream_path(imdb_id, type, season: nil, episode: nil)
    base = @rd_api_key.present? ? "/realdebrid=#{@rd_api_key}" : ""

    episode_path = if type.to_s.in?(%w[show series]) && season && episode
      "series/#{imdb_id}:#{season}:#{episode}"
    else
      "movie/#{imdb_id}"
    end

    "#{base}/stream/#{episode_path}.json"
  end

  def parse_streams(raw_streams)
    raw_streams.map do |s|
      title_text = s["title"].to_s
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
        filename: s.dig("behaviorHints", "filename")
      }
    end
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

  def normalize_cinemeta(meta, type)
    {
      imdb_id: meta["imdb_id"] || meta["id"],
      title: meta["name"],
      year: meta["releaseInfo"] || meta["year"],
      type: type == "series" ? "show" : type,
      poster_url: meta["poster"],
      imdb_rating: meta["imdbRating"]
    }
  end

  def normalize_cinemeta_meta(meta, type)
    {
      imdb_id: meta["imdb_id"] || meta["id"],
      title: meta["name"],
      year: meta["year"] || meta["releaseInfo"],
      type: type,
      poster_url: meta["poster"],
      background_url: meta["background"],
      plot: meta["description"],
      genre: meta["genres"]&.join(", "),
      director: meta["director"]&.join(", "),
      actors: meta["cast"]&.join(", "),
      rated: meta["certification"],
      imdb_rating: meta["imdbRating"],
      runtime: meta["runtime"],
      total_seasons: extract_total_seasons(meta),
      episodes: extract_episodes(meta)
    }
  end

  def extract_total_seasons(meta)
    videos = meta["videos"]
    return nil unless videos.is_a?(Array)
    videos.map { |v| v["season"] }.compact.max
  end

  def extract_episodes(meta)
    videos = meta["videos"]
    return [] unless videos.is_a?(Array)

    videos.select { |v| v["episode"] }.map do |v|
      {
        season: v["season"],
        episode: v["episode"],
        title: v["name"].presence || "Episode #{v["episode"]}",
        released: v["released"]&.to_date&.to_s,
        imdb_id: v["id"]
      }
    end
  end
end
