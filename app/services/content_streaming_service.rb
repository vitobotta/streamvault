# frozen_string_literal: true

class ContentStreamingService
  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new
    @rd = RealDebridService.new(user.realdebrid_api_key)
  end

  # Start a stream for the given content
  def start_stream(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    # Fetch available streams from Torrentio
    streams_result = @torrentio.streams(imdb_id, type, season: season, episode: episode)
    return streams_result if streams_result.failure?

    streams = streams_result.data
    return ServiceResult.failure("No streams available for this content") if streams.empty?

    # Pick the best stream (prefer higher seeders, known quality)
    best_stream = pick_best_stream(streams)
    return ServiceResult.failure("No suitable stream found") unless best_stream

    # Construct magnet link from info_hash
    magnet = "magnet:?xt=urn:btih:#{best_stream[:info_hash]}"

    # Add magnet to RealDebrid
    add_result = @rd.add_magnet(magnet)
    return add_result if add_result.failure?

    torrent_id = add_result.data[:id]

    # Select the target file if file_idx is present
    if best_stream[:file_idx]
      @rd.select_files(torrent_id, best_stream[:file_idx])
    end

    ServiceResult.success({
      torrent_id: torrent_id,
      stream: best_stream,
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode
    })
  end

  # Get the streaming URL for a torrent
  def get_streaming_url(torrent_id, file_idx = nil)
    info_result = @rd.torrent_info(torrent_id)
    return info_result if info_result.failure?

    info = info_result.data

    case info[:status]
    when "downloaded"
      # Find the download link
      link = find_download_link(info, file_idx)
      return ServiceResult.failure("Download link not found") unless link

      unrestrict_result = @rd.unrestrict_link(link)
      return unrestrict_result if unrestrict_result.failure?

      ServiceResult.success({
        streaming_url: unrestrict_result.data[:download_link],
        filename: unrestrict_result.data[:filename],
        filesize: unrestrict_result.data[:filesize],
        status: "ready"
      })
    when "downloading", "queued", "magnet_conversion"
      ServiceResult.success({
        status: info[:status],
        progress: info[:progress],
        speed: info[:speed]
      })
    else
      ServiceResult.failure("Torrent status: #{info[:status]}")
    end
  end

  private

  def pick_best_stream(streams)
    streams
      .select { |s| s[:info_hash].present? }
      .sort_by { |s| -(s[:seeders] || 0) }
      .first
  end

  def find_download_link(info, file_idx)
    if file_idx && info[:links][file_idx.to_i]
      info[:links][file_idx.to_i]
    else
      info[:links].first
    end
  end
end
