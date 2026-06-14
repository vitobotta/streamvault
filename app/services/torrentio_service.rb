# frozen_string_literal: true

class TorrentioService
  TORRENTIO_URL = ENV.fetch("TORRENTIO_API_BASE_URL", "https://torrentio.strem.fun")
  CINEMETA_URL = "https://v3-cinemeta.strem.io"

  def initialize
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
      parsed = sort_streams(parsed, title)
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

  STOP_WORDS = %w[the a an of in on at to for is it and or but not with by from]

  def sort_streams(streams, title)
    title_words = if title.present?
      title.to_s.downcase.split(/\s+/).map { |w| w.gsub(/[^a-z0-9]/, "") }.reject { |w| w.length < 3 || STOP_WORDS.include?(w) }
    else
      []
    end

    # Score: RD+ bonus + word match count
    scored = streams.map do |s|
      first_line = s[:title].to_s.split("\n").first.to_s.downcase
      word_score = title_words.count { |w| first_line.include?(w) }
      rd_score = s[:rd_plus] ? 100 : 0
      [s, rd_score + word_score]
    end

    # Sort by score descending, stable within same score (keeps Torrentio order)
    scored.sort_by.with_index { |item, i| [-item[1], i] }.map { |s, _| s }
  end

  def build_stream_path(imdb_id, type, season: nil, episode: nil)
    if type.to_s.in?(%w[show series]) && season && episode
      "/stream/series/#{imdb_id}:#{season}:#{episode}.json"
    else
      "/stream/movie/#{imdb_id}.json"
    end
  end

  def parse_streams(raw_streams)
    raw_streams.map do |s|
      {
        title: s["title"],
        info_hash: s["infoHash"],
        file_idx: s["fileIdx"],
        name: s["name"],
        quality: extract_quality(s["title"] || s["name"]),
        seeders: extract_seeders(s),
        size: s["size"] ? format_size(s["size"]) : "Unknown",
        raw_size: s["size"],
        rd_plus: s["sources"].is_a?(Array) && s["sources"].any?
      }
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
