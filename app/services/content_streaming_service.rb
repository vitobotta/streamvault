# frozen_string_literal: true

class ContentStreamingService
  MAX_STREAM_ATTEMPTS = 15

  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new(rd_api_key: user.realdebrid_api_key)
  end

  def start_stream(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    meta = @torrentio.metadata(imdb_id, type)
    content_title = meta.success? ? meta.data[:title] : nil

    streams_result = @torrentio.streams(imdb_id, type, season: season, episode: episode, title: content_title, preferred_languages: @user.preferred_stream_languages)
    return streams_result if streams_result.failure?

    streams = streams_result.data
    return ServiceResult.failure("No streams available for this content") if streams.empty?

    candidates = streams.first(MAX_STREAM_ATTEMPTS).select { |s| s[:resolve_url].present? }
    result = resolve_first_valid(candidates)

    if result
      torrent_filename = result[:stream][:filename].presence || result[:filename]

      ServiceResult.success({
        streaming_url: result[:streaming_url],
        filename: torrent_filename,
        stream: result[:stream],
        imdb_id: imdb_id,
        type: type,
        season: season,
        episode: episode
      })
    else
      ServiceResult.failure("No instant streams available. All streams are blocked or unavailable.")
    end
  end

  # Resolve a specific stream chosen by the user (via resolve_url).
  # Unlike start_stream which races all candidates, this resolves
  # exactly the stream the user clicked — respecting their choice
  # of a Direct Play MP4 over an MKV that needs transcoding.
  def resolve_single(resolve_url, filename:, imdb_id:, type:, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    resolved = verify_resolve_url(resolve_url)
    if resolved
      torrent_filename = filename.presence || resolved[:filename]

      ServiceResult.success({
        streaming_url: resolved[:streaming_url],
        filename: torrent_filename,
        stream: { filename: torrent_filename },
        imdb_id: imdb_id,
        type: type,
        season: season,
        episode: episode
      })
    else
      ServiceResult.failure("Could not resolve the selected stream. It may be blocked or unavailable.")
    end
  end

  private

  BLOCKED_PATTERNS = /downloading|infringing|failed.infringement|removed|blocked/i

  def resolve_first_valid(candidates)
    mutex = Mutex.new
    winner = nil

    threads = candidates.map do |stream|
      Thread.new(stream) do |s|
        already_done = mutex.synchronize { !!winner }
        next if already_done

        resolved = verify_resolve_url(s[:resolve_url])
        if resolved
          mutex.synchronize { winner ||= { **resolved, stream: s } }
        end
      end
    end

    threads.each(&:join)
    winner
  end

  def verify_resolve_url(resolve_url)
    response = resolve_faraday.get(resolve_url)

    if [301, 302, 303, 307, 308].include?(response.status)
      location = response.headers["location"]
      return nil if location.blank?
      return nil if location.match?(BLOCKED_PATTERNS)
      filename = location.split("/").last.to_s
      return nil if filename.match?(BLOCKED_PATTERNS)
      { streaming_url: location, filename: filename }
    elsif [200, 206].include?(response.status)
      filename = resolve_url.split("/").last.to_s
      return nil if filename.match?(BLOCKED_PATTERNS)
      { streaming_url: resolve_url, filename: filename }
    else
      nil
    end
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    nil
  end

  def resolve_faraday
    @resolve_faraday ||= begin
      proxy = ENV["TORRENTIO_PROXY"]
      Faraday.new do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
        f.proxy = proxy if proxy.present?
      end
    end
  end
end
