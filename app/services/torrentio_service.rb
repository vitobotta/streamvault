# frozen_string_literal: true

class TorrentioService
  TORRENTIO_URL = ENV.fetch("TORRENTIO_API_BASE_URL", "https://torrentio.strem.fun")
  CINEMETA_URL = "https://v3-cinemeta.strem.io"
  QUALITY_SORT = { "4K" => 0, "1080p" => 1, "720p" => 2, "480p" => 3, "Unknown" => 4 }.freeze

  LANGUAGE_PATTERNS = {
    "ENG" => /\b(ENG|ENGLISH|EN)\b/i,
    "FRENCH" => /\b(FRENCH|FR|VFF|VFQ|TRUEFRENCH)\b/i,
    "GERMAN" => /\b(GERMAN|GER|DE)\b/i,
    "SPANISH" => /\b(SPANISH|SPA|ES|CASTELLANO)\b/i,
    "ITALIAN" => /\b(ITALIAN|ITA|IT)\b/i,
    "JAPANESE" => /\b(JAPANESE|JAP|JA)\b/i,
    "KOREAN" => /\b(KOREAN|KOR|KO)\b/i,
    "CHINESE" => /\b(CHINESE|CHI|ZH)\b/i,
    "HINDI" => /\b(HINDI|HIN|HI)\b/i,
    "ARABIC" => /\b(ARABIC|ARA|AR)\b/i,
    "PORTUGUESE" => /\b(PORTUGUESE|POR|PT|PTBR|BRAZILIAN)\b/i,
    "RUSSIAN" => /\b(RUSSIAN|RUS|RU)\b/i,
    "DUTCH" => /\b(DUTCH|DUT|NL|NLD)\b/i,
    "POLISH" => /\b(POLISH|POL|PL)\b/i,
    "TURKISH" => /\b(TURKISH|TUR|TR)\b/i,
    "SWEDISH" => /\b(SWEDISH|SWE|SV)\b/i
  }.freeze

  BROWSER_VIDEO_CODECS = /x264|h\.?264|x265|h\.?265|hevc|avc|vp9|av1/i
  BROWSER_AUDIO_CODECS = /aac|ac3|eac3|dd[p+]?\b|opus|mp3|flac/i
  INCOMPATIBLE_VIDEO = /mpeg-?2|vc-?1|wmv|realvideo/i
  INCOMPATIBLE_AUDIO = /dts[-\s]?(?:hd|ma)|truehd|pcm|lpcm/i

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

  def streams(imdb_id, type, season: nil, episode: nil, title: nil, preferred_languages: nil)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

    path = build_stream_path(imdb_id, type, season: season, episode: episode)
    response = @torrentio.get(path)

    if response.success? && response.body.is_a?(Hash) && response.body["streams"]
      parsed = parse_streams(response.body["streams"])
      parsed = sort_streams(parsed)
      parsed = filter_by_preferred_languages(parsed, preferred_languages) if preferred_languages.present?
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
      result = normalize_cinemeta_meta(response.body["meta"], type)
      result.merge!(fetch_omdb_ratings(imdb_id))
      ServiceResult.success(result)
    else
      ServiceResult.failure("Metadata not found")
    end
  rescue StandardError => e
    Rails.logger.error("TorrentioService#metadata error: #{e.message}")
    ServiceResult.failure("Failed to fetch metadata")
  end

  def popular(type, limit: 20)
    catalog(type, "top", limit: limit)
  end

  def trending(type, limit: 20)
    catalog(type, "year", genre: Date.today.year.to_s, limit: limit)
  end

  def featured(type, limit: 20)
    catalog(type, "imdbRating", limit: limit)
  end

  private

  def filter_by_preferred_languages(streams, preferred_languages)
    return streams if preferred_languages.blank?
    langs = Array(preferred_languages).map(&:to_s).map(&:upcase)
    streams.select { |s| (s[:languages] & langs).any? }
  end

  def catalog(type, catalog_id, genre: nil, limit: 20)
    cinemeta_type = type.to_s == "show" ? "series" : type.to_s
    path = "catalog/#{cinemeta_type}/#{catalog_id}.json"
    path += "?genre=#{CGI.escape(genre)}" if genre.present?

    response = @cinemeta.get(path)
    if response.success? && response.body.is_a?(Hash)
      metas = (response.body["metas"] || []).first(limit)
      ServiceResult.success(metas.map { |m| normalize_cinemeta(m, type.to_s) })
    else
      ServiceResult.success([])
    end
  rescue StandardError => e
    Rails.logger.error("TorrentioService#catalog error: #{e.message}")
    ServiceResult.success([])
  end

  def sort_streams(streams)
    streams.sort_by do |s|
      video_compat = s[:video_codec] == "incompatible" ? 1 : 0
      audio_compat = s[:audio_codec] == "incompatible" ? 1 : 0
      rd_score = s[:rd_plus] ? 0 : 1
      quality_score = QUALITY_SORT[s[:quality]] || 4
      size_bytes = s[:raw_size].is_a?(Numeric) ? s[:raw_size] : 0
      [video_compat, audio_compat, rd_score, quality_score, -size_bytes]
    end
  end

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
        filename: s.dig("behaviorHints", "filename"),
        resolve_url: s["url"],
        languages: extract_languages(title_text),
        video_codec: extract_video_codec(title_text),
        audio_codec: extract_audio_codec(title_text)
      }
    end
  end

  def extract_languages(title)
    return ["ENG"] if title.blank?
    langs = LANGUAGE_PATTERNS.select { |_, pattern| title.match?(pattern) }.keys
    langs = LANGUAGE_PATTERNS.keys if title.match?(/\bMULTi|MULTIPLE|MULTI\b/i)
    langs.presence || ["ENG"]
  end

  def extract_video_codec(title)
    return "unknown" if title.blank?
    return "incompatible" if title.match?(INCOMPATIBLE_VIDEO)
    match = title.match(BROWSER_VIDEO_CODECS)
    match ? match[0].upcase : "unknown"
  end

  def extract_audio_codec(title)
    return "unknown" if title.blank?
    return "incompatible" if title.match?(INCOMPATIBLE_AUDIO)
    match = title.match(BROWSER_AUDIO_CODECS)
    match ? match[0].upcase : "unknown"
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

  def fetch_omdb_ratings(imdb_id)
    api_key = ENV.fetch("OMDB_API_KEY", "")
    return {} if api_key.blank? || api_key == "your_omdb_api_key_here"

    response = Faraday.get("https://www.omdbapi.com/", { i: imdb_id, apikey: api_key, tomatoes: "true" })
    data = JSON.parse(response.body)
    return {} unless data["Response"] == "True"

    rt_rating = nil
    if data["Ratings"].is_a?(Array)
      rt = data["Ratings"].find { |r| r["Source"] == "Rotten Tomatoes" }
      rt_rating = rt["Value"] if rt
    end

    {
      rated: data["Rated"] != "N/A" ? data["Rated"] : nil,
      rt_rating: rt_rating,
      metascore: data["Metascore"] != "N/A" ? data["Metascore"] : nil
    }
  rescue StandardError
    {}
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
        imdb_id: v["id"],
        overview: v["overview"],
        runtime: v["runtime"]
      }
    end
  end
end
