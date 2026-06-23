# frozen_string_literal: true

require "cgi"

class SubdlSubtitleProvider
  API_BASE_URL = ENV.fetch("SUBDL_API_BASE_URL", "https://api.subdl.com")
  LEGACY_DOWNLOAD_BASE_URL = ENV.fetch("SUBDL_DOWNLOAD_BASE_URL", "https://dl.subdl.com")
  SEARCH_PATH = "api/v2/subtitles/search"
  DOWNLOAD_PATH_PATTERN = %r{\A/api/v2/subtitles/[^/]+/download\z}
  MAX_RESULTS = 12
  SUPPORTED_FORMATS = %w[srt vtt].freeze
  FORCED_RELEASE_PATTERN = /\bforced\b/i
  PARTIAL_RELEASE_PATTERN = /\b(forced|signs?\s*(?:&|and)?\s*songs?|songs?\s*(?:&|and)?\s*signs?|lyrics?|karaoke|commentary|comment)\b/i
  LANGUAGE_CODES = {
    "ENG" => "en",
    "FRENCH" => "fr",
    "GERMAN" => "de",
    "SPANISH" => "es",
    "ITALIAN" => "it",
    "JAPANESE" => "ja",
    "KOREAN" => "ko",
    "CHINESE" => "zh",
    "HINDI" => "hi",
    "ARABIC" => "ar",
    "PORTUGUESE" => "pt",
    "RUSSIAN" => "ru",
    "DUTCH" => "nl",
    "POLISH" => "pl",
    "TURKISH" => "tr",
    "SWEDISH" => "sv"
  }.freeze

  def initialize(api_key: ENV["SUBDL_API_KEY"], search_connection: nil, download_connection: nil)
    @api_key = api_key.to_s.strip
    @search_connection = search_connection || build_search_connection
    @download_connection = download_connection || build_download_connection
    @legacy_download_connection = download_connection if download_connection
  end

  def available?
    @api_key.present?
  end

  def search(imdb_id:, type:, season: nil, episode: nil, title: nil, filename: nil, preferred_languages: [], default_language: nil)
    unless available?
      Rails.logger.info("[SubDL] subtitle search disabled: SUBDL_API_KEY is not configured")
      return []
    end
    return [] unless imdb_id.present? || filename.present? || title.present?

    response = @search_connection.get(SEARCH_PATH, search_params(
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode,
      title: title,
      filename: filename,
      preferred_languages: preferred_languages,
      default_language: default_language
    )) { |request| authenticate_request(request) }
    unless response.success? && response.body.is_a?(Hash)
      log_unsuccessful_response("search", response)
      return []
    end

    normalize_tracks(response.body, preferred_languages: preferred_languages, default_language: default_language)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
    Rails.logger.info("[SubDL] subtitle search unavailable: #{e.class.name}")
    []
  rescue StandardError => e
    Rails.logger.error("[SubDL] subtitle search failed: #{e.class.name}")
    []
  end

  def download(path)
    return ServiceResult.failure("Invalid subtitle download path") unless valid_download_path?(path)

    response = download_connection(path).get(normalized_download_path(path)) { |request| authenticate_download_request(request, path) }
    return ServiceResult.failure("Subtitle download failed", response.status) unless response.success?

    ServiceResult.success(response.body.to_s)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    ServiceResult.failure("Subtitle download timed out")
  rescue StandardError => e
    Rails.logger.error("[SubDL] subtitle download failed: #{e.class.name}")
    ServiceResult.failure("Subtitle download failed")
  end

  private

  def build_search_connection
    Faraday.new(url: API_BASE_URL) do |f|
      f.response :json
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
      f.options.timeout = 12
      f.options.open_timeout = 5
    end
  end

  def build_download_connection
    Faraday.new(url: API_BASE_URL) do |f|
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
      f.options.timeout = 12
      f.options.open_timeout = 5
    end
  end

  def search_params(imdb_id:, type:, season:, episode:, title:, filename:, preferred_languages:, default_language:)
    params = {
      type: subdl_type(type),
      languages: language_codes(preferred_languages, default_language).join(","),
      unpack: "1",
      subs_per_page: MAX_RESULTS.to_s
    }
    if imdb_id.present?
      params[:imdb_id] = imdb_id.to_s
    elsif filename.present?
      params[:file_name] = filename.to_s
    else
      params[:film_name] = title.to_s
    end
    params[:season] = season.to_i if season.to_i.positive?
    params[:episode] = episode.to_i if episode.to_i.positive?
    params.compact
  end

  def subdl_type(type)
    type.to_s.in?(%w[show series tv]) ? "tv" : "movie"
  end

  def language_codes(preferred_languages, default_language)
    languages = ([ default_language ] + Array(preferred_languages))
      .map(&:to_s)
      .map(&:upcase)
      .filter_map { |language| LANGUAGE_CODES[language] }
      .uniq
    languages.presence || [ "en" ]
  end

  def normalize_tracks(body, preferred_languages:, default_language:)
    language_priority = language_codes(preferred_languages, default_language)
    tracks = subtitle_items(body).flat_map { |subtitle| normalize_subtitle(subtitle) }
    tracks
      .sort_by { |track| track_score(track, language_priority) }
      .first(MAX_RESULTS)
  end

  def normalize_subtitle(subtitle)
    files = Array(subtitle["unpack_files"]).presence || Array(subtitle["files"]).presence || [ subtitle ]
    files.filter_map do |file|
      download_path = download_path_for(file, subtitle)
      format = subtitle_format(file, subtitle, download_path)
      next unless SUPPORTED_FORMATS.include?(format.to_s.downcase)
      next unless valid_download_path?(download_path)

      language = language_from_code(file["language"].presence || file["language_code"].presence || subtitle["language"].presence || subtitle["language_code"])
      release_name = file["release_name"].presence || subtitle["release_name"].presence || file["name"].presence || subtitle["name"].presence
      hearing_impaired = truthy?(file["hi"]) || truthy?(subtitle["hi"]) || truthy?(file["hearing_impaired"]) || truthy?(subtitle["hearing_impaired"])
      forced = release_name.to_s.match?(FORCED_RELEASE_PATTERN)
      partial = release_name.to_s.match?(PARTIAL_RELEASE_PATTERN)

      {
        index: ExternalSubtitleService.stream_id("subdl", download_path),
        position: nil,
        language: language,
        language_label: language_label(language),
        title: external_title(release_name, hearing_impaired),
        codec: format.to_s.downcase,
        default: false,
        text_supported: true,
        forced: forced,
        hearing_impaired: hearing_impaired,
        commentary: release_name.to_s.match?(/\bcomment(?:ary)?\b/i),
        partial: partial,
        quality: partial ? "partial" : "full",
        quality_score: track_score_value(partial: partial, hearing_impaired: hearing_impaired),
        external: true,
        source: "subdl",
        download_path: download_path,
        label: external_label(language, release_name, hearing_impaired)
      }
    end
  end

  def subtitle_items(body)
    Array(body["subtitles"]).presence ||
      Array(body["results"]).presence ||
      Array(body["data"]).presence ||
      []
  end

  def download_path_for(file, subtitle)
    candidates = [
      file["download_url"].presence,
      file["url"].presence,
      subtitle["download_url"].presence,
      subtitle["url"].presence,
      unpack_file_download_path(
        file["n_id"].presence || file["nId"].presence || file["id"].presence || subtitle["n_id"].presence || subtitle["nId"].presence || subtitle["id"]
      )
    ]
    candidates.find { |candidate| valid_download_path?(candidate) }
  end

  def unpack_file_download_path(n_id)
    return nil if n_id.blank?

    "/api/v2/subtitles/#{CGI.escape(n_id.to_s)}/download?format=file"
  end

  def subtitle_format(file, subtitle, download_path)
    file["format"].presence ||
      file["file_format"].presence ||
      file["extension"].presence ||
      subtitle["format"].presence ||
      subtitle["file_format"].presence ||
      subtitle["extension"].presence ||
      File.extname(download_path.to_s).delete_prefix(".").presence ||
      "srt"
  end

  def external_title(release_name, hearing_impaired)
    parts = []
    parts << "SubDL"
    parts << "SDH" if hearing_impaired
    parts << release_name.to_s.truncate(80) if release_name.present?
    parts.join(" · ")
  end

  def external_label(language, release_name, hearing_impaired)
    parts = [ language_label(language), "SubDL" ]
    parts << "SDH" if hearing_impaired
    parts << release_name.to_s.truncate(80) if release_name.present?
    parts.join(" · ")
  end

  def track_score(track, language_priority)
    language_index = language_priority.index(LANGUAGE_CODES[track[:language]]) || language_priority.length
    [ language_index, track[:quality_score].to_i, track[:label].to_s.length ]
  end

  def track_score_value(partial:, hearing_impaired:)
    score = 0
    score += 100 if partial
    score += 20 if hearing_impaired
    score
  end

  def language_from_code(code)
    normalized = code.to_s.downcase
    LANGUAGE_CODES.find { |_, subdl_code| subdl_code == normalized }&.first || "ENG"
  end

  def language_label(language)
    User::STREAM_LANGUAGE_OPTIONS[language] || language || "Unknown"
  end

  def authenticate_request(request)
    request.headers["Authorization"] = "Bearer #{@api_key}"
  end

  def valid_download_path?(path)
    normalized = path.to_s
    return false if normalized.blank?

    uri = URI.parse(normalized)
    if uri.relative?
      api_download_path?(normalized) || normalized.start_with?("/subtitle/")
    else
      uri.is_a?(URI::HTTPS) &&
        (
          (uri.host == "api.subdl.com" && api_download_path?(uri.path)) ||
          (uri.host == "dl.subdl.com" && uri.path.start_with?("/subtitle/"))
        )
    end
  rescue URI::InvalidURIError
    false
  end

  def normalized_download_path(path)
    uri = URI.parse(path.to_s)
    uri.relative? ? path.to_s : uri.request_uri
  end

  def api_download_path?(path)
    URI.parse(path.to_s).path.match?(DOWNLOAD_PATH_PATTERN)
  rescue URI::InvalidURIError
    false
  end

  def download_connection(path)
    URI.parse(path.to_s).path.start_with?("/subtitle/") ? legacy_download_connection : @download_connection
  rescue URI::InvalidURIError
    @download_connection
  end

  def legacy_download_connection
    @legacy_download_connection ||= Faraday.new(url: LEGACY_DOWNLOAD_BASE_URL) do |f|
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
      f.options.timeout = 12
      f.options.open_timeout = 5
    end
  end

  def authenticate_download_request(request, path)
    if api_download_path?(normalized_download_path(path))
      authenticate_request(request)
    elsif @api_key.present?
      request.headers["x-api-key"] = @api_key
    end
  end

  def log_unsuccessful_response(action, response)
    code = response.body.is_a?(Hash) ? response.body.dig("error", "code") || response.body["error"] : nil
    detail = code.present? ? ": #{code}" : ""
    detail += " (check SUBDL_API_KEY)" if response.status.to_i == 401
    Rails.logger.info("[SubDL] subtitle #{action} rejected#{detail} (HTTP #{response.status})")
  end

  def truthy?(value)
    value == true || value.to_s == "1" || value.to_s.casecmp("true").zero?
  end
end
