# frozen_string_literal: true

class ContentStreamingService
  CACHE_CHECK_ATTEMPTS = 20
  CACHE_CHECK_INTERVAL = 1

  def initialize(user)
    @user = user
    @torrentio = TorrentioService.new
    @rd = RealDebridService.new(user.realdebrid_api_key)
  end

  # Start a stream — only returns torrents that are cached on RealDebrid
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
        cached = wait_for_cache(torrent_id)
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

  # Get the streaming URL — uses file_idx to select the correct file
  def get_streaming_url(torrent_id, file_idx = nil)
    info = fetch_torrent_info(torrent_id)
    return info if info.is_a?(ServiceResult) && info.failure?

    # Always try to select the correct file based on file_idx
    # RealDebrid allows re-selecting files even if some were already selected
    if info[:files].any? && file_idx.present?
      target_id = find_file_by_idx(info[:files], file_idx)
      @rd.select_files(torrent_id, target_id) if target_id
      # Re-fetch after selection to get updated links
      info = fetch_torrent_info(torrent_id)
      return info if info.is_a?(ServiceResult) && info.failure?
    elsif info[:files].any? && info[:files].none? { |f| f[:selected] }
      # No file_idx and nothing selected — pick the largest
      target_id = find_largest_file_id(info[:files])
      @rd.select_files(torrent_id, target_id) if target_id
      info = fetch_torrent_info(torrent_id)
      return info if info.is_a?(ServiceResult) && info.failure?
    end

    # Get the link for the correct file
    link = find_link_for_file(info, file_idx)
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

  def wait_for_cache(torrent_id)
    CACHE_CHECK_ATTEMPTS.times do
      sleep CACHE_CHECK_INTERVAL
      info = fetch_torrent_info(torrent_id)
      next unless info.is_a?(Hash)

      case info[:status]
      when "downloaded"
        return true
      when "waiting_files_selection"
        # DON'T select files here — get_streaming_url will select the right one
        # Just select all files to trigger download
        all_file_ids = info[:files].map { |f| f[:id] }
        @rd.select_files(torrent_id, all_file_ids) if all_file_ids.any?
      else
        next
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

  # Map Torrentio's file_idx (0-based) to RealDebrid's file ID
  def find_file_by_idx(files, file_idx)
    return nil if file_idx.nil?
    idx = file_idx.to_i
    file = files[idx]
    file&.dig(:id)
  end

  def find_largest_file_id(files)
    largest = files.max_by { |f| f[:bytes] || 0 }
    largest&.dig(:id)
  end

  # Find the download link for the correct file
  def find_link_for_file(info, file_idx)
    return info[:links]&.first if file_idx.nil?

    idx = file_idx.to_i
    link = info[:links][idx]
    return link if link

    info[:links]&.first
  end
end
