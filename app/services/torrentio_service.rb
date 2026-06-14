# frozen_string_literal: true

class TorrentioService
  BASE_URL = ENV.fetch("TORRENTIO_API_BASE_URL", "https://torrentio.strem.fun")

  def initialize
    @conn = Faraday.new(url: BASE_URL) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 15
      f.options.open_timeout = 5
    end
  end

  # Search for content using OMDB API, then fetch streams per result
  def search(query)
    return ServiceResult.failure("Query cannot be blank") if query.blank?

    # Use OMDB API for search
    omdb_result = search_omdb(query)
    return omdb_result if omdb_result.failure?

    results = omdb_result.data
    # Enrich each result with stream availability
    enriched = results.map do |item|
      streams_result = streams(item[:imdb_id], item[:type])
      item[:streams_available] = streams_result.success? ? streams_result.data.any? : false
      item
    end

    ServiceResult.success(enriched)
  rescue Faraday::TimeoutError
    ServiceResult.failure("Search request timed out")
  rescue Faraday::ConnectionFailed
    ServiceResult.failure("Could not connect to search service")
  rescue StandardError => e
    Rails.logger.error("TorrentioService#search error: #{e.message}")
    ServiceResult.failure("An unexpected error occurred")
  end

  # Fetch streams for a specific content item
  def streams(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

    path = build_stream_path(imdb_id, type, season: season, episode: episode)
    response = @conn.get(path)

    if response.success? && response.body.is_a?(Hash) && response.body["streams"]
      streams = parse_streams(response.body["streams"])
      ServiceResult.success(streams)
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

  # Fetch metadata from OMDB API
  def metadata(imdb_id, type)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

    response = Faraday.get("https://www.omdbapi.com/", {
      i: imdb_id,
      apikey: ENV.fetch("OMDB_API_KEY", ""),
      type: type == "show" ? "series" : type
    })

    data = JSON.parse(response.body)
    if data["Response"] == "True"
      ServiceResult.success(normalize_omdb_metadata(data))
    else
      ServiceResult.failure(data["Error"] || "Metadata not found")
    end
  rescue StandardError => e
    Rails.logger.error("TorrentioService#metadata error: #{e.message}")
    ServiceResult.failure("Failed to fetch metadata")
  end

  private

  def search_omdb(query)
    response = Faraday.get("https://www.omdbapi.com/", {
      s: query,
      apikey: ENV.fetch("OMDB_API_KEY", "")
    })

    data = JSON.parse(response.body)
    if data["Response"] == "True" && data["Search"]
      results = data["Search"].map { |item| normalize_omdb_search(item) }
      ServiceResult.success(results)
    else
      ServiceResult.success([])
    end
  rescue StandardError => e
    Rails.logger.error("TorrentioService#search_omdb error: #{e.message}")
    ServiceResult.failure("Search failed")
  end

  def build_stream_path(imdb_id, type, season: nil, episode: nil)
    if type.to_s == "show" && season && episode
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
        raw_size: s["size"]
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

  def normalize_omdb_search(item)
    {
      imdb_id: item["imdbID"],
      title: item["Title"],
      year: item["Year"],
      type: item["Type"] == "series" ? "show" : "movie",
      poster_url: item["Poster"] != "N/A" ? item["Poster"] : nil
    }
  end

  def normalize_omdb_metadata(data)
    {
      imdb_id: data["imdbID"],
      title: data["Title"],
      year: data["Year"],
      type: data["Type"] == "series" ? "show" : "movie",
      poster_url: data["Poster"] != "N/A" ? data["Poster"] : nil,
      plot: data["Plot"],
      genre: data["Genre"],
      director: data["Director"],
      actors: data["Actors"],
      rated: data["Rated"],
      imdb_rating: data["imdbRating"],
      total_seasons: data["totalSeasons"]&.to_i
    }
  end
end
