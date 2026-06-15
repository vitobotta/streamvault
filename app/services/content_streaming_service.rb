# frozen_string_literal: true

class ContentStreamingService
  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new(rd_api_key: user.realdebrid_api_key)
  end

  # Start a stream — returns the Torrentio resolve URL
  # Torrentio handles RealDebrid integration server-side:
  # 1. Adds magnet to RealDebrid
  # 2. Selects the correct file
  # 3. Returns a URL that 302-redirects to the RealDebrid streaming link
  def start_stream(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    meta = @torrentio.metadata(imdb_id, type)
    content_title = meta.success? ? meta.data[:title] : nil

    streams_result = @torrentio.streams(imdb_id, type, season: season, episode: episode, title: content_title)
    return streams_result if streams_result.failure?

    streams = streams_result.data
    return ServiceResult.failure("No streams available for this content") if streams.empty?

    # Pick the best stream (first in sorted order — already sorted by RD+, quality, size)
    best = streams.first

    if best[:resolve_url].present?
      ServiceResult.success({
        resolve_url: best[:resolve_url],
        stream: best,
        imdb_id: imdb_id,
        type: type,
        season: season,
        episode: episode
      })
    else
      ServiceResult.failure("No playable stream found. Try a different quality.")
    end
  end
end
