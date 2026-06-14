# frozen_string_literal: true

class ContentStreamingService
  CACHE_CHECK_ATTEMPTS = 15
  CACHE_CHECK_INTERVAL = 1

  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new
    @rd = RealDebridService.new(user.realdebrid_api_key)
  end

  def start_stream(imdb_id, type, season: nil, episode: nil)
    return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

    meta = @torrentio.metadata(imdb_id, type)
    content_title = meta.success? ? meta.data[:title] : nil

    streams_result = @torrentio.streams(imdb_id, type, season: season, episode: episode, title: content_title)
    return streams_result if streams_result.failure?

    streams = streams_result.data.select { |s| s[:info_hash].present? }
    return ServiceResult.failure("No streams available for this content") if streams.empty?

    sorted = streams.sort_by { |s| -(s[:seeders] || 0) }.first(15)

    sorted.each_with_index do |stream, i|
      sleep 0.3 if i > 0
      magnet = "magnet:?xt=urn:btih:#{stream[:info_hash]}"
      add_result = @rd.add_magnet(magnet)

      if add_result.success?
        torrent_id = add_result.data[:id]
        cached = wait_for_cache(torrent_id, stream[:file_idx])
        if cached
          return ServiceResult.success({
            torrent_id: torrent_id,
            file_idx: stream[:file_idx],
            stream: stream,
            imdb_id: imdb_id,
            type: type,
            season: season,
            episode: episode
          })
        end
        cleanup_torrent(torrent_id)
      end
    end

    ServiceResult.failure("No instant streams available. Try a different quality or wait for downloads.")
  end

  def get_streaming_url(torrent_id, file_idx = nil)
    info = fetch_torrent_info(torrent_id)
    return info if info.is_a?(ServiceResult) && info.failure?

    # Select files if nothing is selected (shouldn't happen if wait_for_cache worked)
    if info[:files].any? && info[:files].none? { |f| f[:selected] }
      target = if file_idx.present?
        info[:files][file_idx.to_i]&.dig(:id)
      end
      target ||= info[:files].max_by { |f| f[:bytes] || 0 }&.dig(:id)
      @rd.select_files(torrent_id, target) if target
      sleep 1
      info = fetch_torrent_info(torrent_id)
      return info if info.is_a?(ServiceResult) && info.failure?
    end

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

    ServiceResult.success({
      status: info[:status],
      progress: info[:progress],
      speed: info[:speed]
    })
  end

  private

  # Select the specific episode file and wait for "downloaded"
  def wait_for_cache(torrent_id, file_idx = nil)
    file_selected = false
    CACHE_CHECK_ATTEMPTS.times do
      sleep CACHE_CHECK_INTERVAL
      info = fetch_torrent_info(torrent_id)
      next unless info.is_a?(Hash)
      return true if info[:status] == "downloaded"

      if info[:status] == "waiting_files_selection" && info[:files].any? && !file_selected
        # Select the specific episode file (via file_idx), or largest as fallback
        target = if file_idx.present?
          info[:files][file_idx.to_i]&.dig(:id)
        end
        target ||= info[:files].max_by { |f| f[:bytes] || 0 }&.dig(:id)
        if target
          @rd.select_files(torrent_id, target)
          file_selected = true
        end
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
    # ignore
  end

  def fetch_torrent_info(torrent_id)
    result = @rd.torrent_info(torrent_id)
    return result if result.failure?
    result.data
  end
end
