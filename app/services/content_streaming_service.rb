# frozen_string_literal: true

class ContentStreamingService
  CACHE_CHECK_ATTEMPTS = 6
  CACHE_CHECK_INTERVAL = 0.5

  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new
    @rd = RealDebridService.new(user.realdebrid_api_key)
  end

  # Start a stream — only returns torrents that are cached on RealDebrid (instant playback)
  def start_stream(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    streams_result = @torrentio.streams(imdb_id, type, season: season, episode: episode)
    return streams_result if streams_result.failure?

    streams = streams_result.data.select { |s| s[:info_hash].present? }
    return ServiceResult.failure("No streams available for this content") if streams.empty?

    sorted = streams.sort_by { |s| -(s[:seeders] || 0) }.first(15)

    sorted.each_with_index do |stream, i|
      sleep 0.2 if i > 0

      magnet = "magnet:?xt=urn:btih:#{stream[:info_hash]}"
      add_result = @rd.add_magnet(magnet)
      next unless add_result.success?

      torrent_id = add_result.data[:id]

      # Check if this torrent is cached — poll briefly
      cached = wait_for_cache(torrent_id)
      if cached
        return ServiceResult.success({
          torrent_id: torrent_id,
          stream: stream,
          imdb_id: imdb_id,
          type: type,
          season: season,
          episode: episode
        })
      end

      # Not cached — clean up and try next stream
      cleanup_torrent(torrent_id)
    end

    ServiceResult.failure("No instant streams available. Try a different quality or wait for downloads.")
  end

  # Get the streaming URL — handles file selection and link retrieval
  def get_streaming_url(torrent_id, _file_idx = nil)
    info = fetch_torrent_info(torrent_id)
    return info if info.is_a?(ServiceResult) && info.failure?

    # Select files if they exist but none are selected
    if info[:files].any? && info[:files].none? { |f| f[:selected] }
      target = find_largest_file_id(info[:files])
      @rd.select_files(torrent_id, target) if target
      info = fetch_torrent_info(torrent_id)
      return info if info.is_a?(ServiceResult) && info.failure?
    end

    # Try to get a streaming link
    link = info[:links]&.first
    if link
      unrestrict_result = @rd.unrestrict_link(link)
      if unrestrict_result.success?
        return ServiceResult.success({
          streaming_url: unrestrict_result.data[:download_link],
          filename: unrestrict_result.data[:filename],
          filesize: unrestrict_result.data[:filesize],
          status: "ready"
        })
      end
    end

    # Not ready yet
    ServiceResult.success({
      status: info[:status],
      progress: info[:progress],
      speed: info[:speed]
    })
  end

  private

  # Poll torrent status briefly to see if it's cached (resolves to downloaded quickly)
  def wait_for_cache(torrent_id)
    CACHE_CHECK_ATTEMPTS.times do
      sleep CACHE_CHECK_INTERVAL
      info = fetch_torrent_info(torrent_id)
      next unless info.is_a?(Hash)

      case info[:status]
      when "downloaded"
        return true
      when "waiting_files_selection"
        # Files available — select largest and check if it resolves
        target = find_largest_file_id(info[:files])
        @rd.select_files(torrent_id, target) if target
        sleep CACHE_CHECK_INTERVAL
        recheck = fetch_torrent_info(torrent_id)
        return true if recheck.is_a?(Hash) && recheck[:status] == "downloaded"
      when "magnet_conversion", "magnet_error"
        next # still converting
      else
        return false # downloading, queued, etc. = not cached
      end
    end
    false
  end

  def cleanup_torrent(torrent_id)
    conn = Faraday.new(url: RealDebridService::BASE_URL) do |f|
      f.headers["Authorization"] = "Bearer #{@user.realdebrid_api_key}"
    end
    conn.delete("torrents/delete/#{torrent_id}")
  rescue StandardError
    # ignore cleanup errors
  end

  def fetch_torrent_info(torrent_id)
    result = @rd.torrent_info(torrent_id)
    return result if result.failure?
    result.data
  end

  def find_largest_file_id(files)
    largest = files.max_by { |f| f[:bytes] || 0 }
    largest&.dig(:id)
  end
end
