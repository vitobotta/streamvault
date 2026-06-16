# frozen_string_literal: true

class ContentStreamingService
  MAX_STREAM_ATTEMPTS = 10
  BLOCKED_PATTERNS = /downloading|infringing|failed.infringement|removed|blocked/i

  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new(rd_api_key: user.realdebrid_api_key)
  end

  # Start a stream — tries multiple streams, returns the first that resolves to a real URL
  def start_stream(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    meta = @torrentio.metadata(imdb_id, type)
    content_title = meta.success? ? meta.data[:title] : nil

    streams_result = @torrentio.streams(imdb_id, type, season: season, episode: episode, title: content_title)
    return streams_result if streams_result.failure?

    streams = streams_result.data
    return ServiceResult.failure("No streams available for this content") if streams.empty?

    streams.first(MAX_STREAM_ATTEMPTS).each do |stream|
      next unless stream[:resolve_url].present?

      result = verify_resolve_url(stream[:resolve_url])
      if result
        return ServiceResult.success({
          streaming_url: result[:streaming_url],
          filename: result[:filename],
          stream: stream,
          imdb_id: imdb_id,
          type: type,
          season: season,
          episode: episode
        })
      end
    end

    ServiceResult.failure("No instant streams available. All streams are blocked or unavailable.")
  end

  private

  def verify_resolve_url(resolve_url)
    response = Faraday.get(resolve_url)

    return nil unless [301, 302, 303, 307, 308].include?(response.status)

    location = response.headers["location"]
    return nil if location.blank?
    return nil if location.match?(BLOCKED_PATTERNS)

    filename = location.split("/").last.to_s
    return nil if filename.match?(BLOCKED_PATTERNS)

    {
      streaming_url: location,
      filename: filename
    }
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    nil
  end
end
