# frozen_string_literal: true

class ProgressTrackingService
  # Save watch progress for content
  def self.save_progress(user, imdb_id, progress_seconds, duration_seconds, type:, season: nil, episode: nil, poster_url: nil, title: nil)
    return ServiceResult.failure("Invalid progress data") if progress_seconds.blank? || duration_seconds.blank?

    progress_seconds = [ progress_seconds.to_i, 0 ].max
    duration_seconds = [ duration_seconds.to_i, 0 ].max
    progress_pct =
      if duration_seconds.positive?
        ((progress_seconds.to_f / duration_seconds) * 100).round.clamp(0, 100)
      elsif progress_seconds.positive?
        1
      else
        0
      end

    resolved_title = title.presence || fetch_title(user, imdb_id, type)
    resolved_poster = poster_url.presence || fetch_poster(user, imdb_id, type)

    # Upsert the watch history entry — one row per movie or per
    # episode, updated in place on every 5s progress save.  The
    # unique key is (user, content_type, imdb_id, show_imdb_id,
    # season_number, episode_number): for movies show_imdb_id is
    # nil and season/episode are 0; for episodes imdb_id holds the
    # show id and show_imdb_id is the same.  This replaces the old
    # create-on-every-save design that produced a row every 5s and
    # required ad-hoc dedup in every consumer.
    content_type_val = type == "show" ? :episode : :movie
    season_val = type == "show" ? season : 0
    episode_val = type == "show" ? episode : 0
    show_imdb_val = type == "show" ? imdb_id : nil
    show_title_val = type == "show" ? resolved_title : nil

    entry = user.watch_history_entries.find_or_initialize_by(
      content_type: content_type_val,
      imdb_id: imdb_id,
      show_imdb_id: show_imdb_val,
      season_number: season_val,
      episode_number: episode_val
    )
    entry.assign_attributes(
      title: resolved_title,
      poster_url: resolved_poster,
      watched_at: Time.current,
      progress_seconds: progress_seconds,
      duration_seconds: duration_seconds,
      progress_percentage: progress_pct,
      show_title: show_title_val
    )
    entry.save!

    # Update episode progress for shows
    if type == "show" && season && episode
      update_episode_progress(user, imdb_id, season, episode, progress_seconds, duration_seconds, resolved_title)
    end

    # Update library entry watch status
    update_library_watch_status(user, imdb_id, type, progress_pct)

    # Refresh recommendations in the background (debounced — only
    # runs once per 10 minutes per user despite 5s progress saves).
    RefreshRecommendationsJob.enqueue_debounced(user.id)

    ServiceResult.success(entry)
  rescue ActiveRecord::RecordInvalid => e
    ServiceResult.failure(e.message)
  rescue StandardError => e
    Rails.logger.error("ProgressTrackingService#save_progress error: #{e.message}")
    ServiceResult.failure("Failed to save progress")
  end

  # Get progress for specific content
  def self.get_progress(user, imdb_id, season: nil, episode: nil)
    if season && episode
      entry = user.episode_progresses.find_by(
        show_imdb_id: imdb_id,
        season_number: season,
        episode_number: episode
      )
    else
      entry = user.watch_history_entries
        .where(imdb_id: imdb_id)
        .order(watched_at: :desc)
        .first
    end

    ServiceResult.success(entry)
  end

  # Determine the next episode of a show from its actual episode list.
  # Derives from Cinemeta metadata (not episode_progresses rows, which only
  # exist for already-watched episodes). Crosses season boundaries.
  def self.next_episode(user, show_imdb_id, season, episode)
    meta = TorrentioService.new(rd_api_key: user.realdebrid_api_key).metadata(show_imdb_id, "show")
    return ServiceResult.failure("Could not load episode list") if meta.failure?

    episodes = meta.data[:episodes].reject { |e| e[:season].to_i == 0 }
    return ServiceResult.failure("No episodes available") if episodes.blank?
    episodes = episodes.sort_by { |e| [ e[:season].to_i, e[:episode].to_i ] }

    current = episodes.find { |e| e[:season].to_i == season.to_i && e[:episode].to_i == episode.to_i }
    idx = current ? episodes.index(current) : nil

    next_ep = idx ? episodes[idx + 1] : nil
    if next_ep.nil?
      next_season = season.to_i + 1
      next_ep = episodes.find { |e| e[:season].to_i == next_season && e[:episode].to_i == 1 }
    end

    if next_ep
      ServiceResult.success({ season: next_ep[:season].to_i, episode: next_ep[:episode].to_i })
    else
      ServiceResult.failure("No more episodes")
    end
  rescue StandardError => e
    Rails.logger.error("ProgressTrackingService#next_episode error: #{e.message}")
    ServiceResult.failure("Could not determine next episode")
  end

  # Get continue watching list — one item per content, deduplicated.
  # save_progress now upserts (one row per movie/episode), so dedup is
  # normally a no-op — kept as a safety net for any pre-migration rows.
  def self.continue_watching(user)
    recent = user.watch_history_entries
      .where("progress_percentage < ?", 95)
      .order(watched_at: :desc)

    seen = {}
    items = recent.filter_map do |e|
      # Dedup by show (not per-episode) so watching S01E03 removes
      # S01E02 from Continue Watching — only the most recent episode
      # per show should appear. Movies dedup by imdb_id.
      key = if e.episode?
              e.show_imdb_id
            else
              e.imdb_id
            end
      next if seen.key?(key)
      seen[key] = true

      {
        imdb_id: e.show_imdb_id.presence || e.imdb_id,
        title: e.show_title.presence || e.title,
        poster_url: e.poster_url,
        content_type: e.content_type,
        season: e.season_number,
        episode: e.episode_number,
        progress_seconds: e.progress_seconds,
        duration_seconds: e.duration_seconds,
        progress_percentage: e.progress_percentage,
        last_watched: e.watched_at,
        history_id: e.id
      }
    end

    ServiceResult.success(items.first(20))
  end

  private

  def self.update_episode_progress(user, show_imdb_id, season, episode, progress_seconds, duration_seconds, show_title)
    ep = user.episode_progresses.find_or_initialize_by(
      show_imdb_id: show_imdb_id,
      season_number: season,
      episode_number: episode
    )

    ep.update!(
      show_title: show_title,
      progress_seconds: progress_seconds,
      duration_seconds: duration_seconds,
      last_watched_at: Time.current
    )
  end

  def self.update_library_watch_status(user, imdb_id, type, progress_pct)
    entry = user.library_entries.find_by(imdb_id: imdb_id)
    return unless entry

    new_status =
      if progress_pct >= 95
        :finished
      elsif progress_pct.positive?
        :watching
      else
        entry.watch_status
      end

    entry.update!(watch_status: new_status) if new_status != entry.watch_status
  end

  def self.fetch_title(user, imdb_id, _type)
    user.library_entries.find_by(imdb_id: imdb_id)&.title || "Unknown"
  end

  def self.fetch_poster(user, imdb_id, type)
    user.library_entries.find_by(imdb_id: imdb_id)&.poster_url ||
      user.wishlist_entries.find_by(imdb_id: imdb_id)&.poster_url ||
      fetch_poster_from_metadata(imdb_id, type)
  end

  def self.fetch_poster_from_metadata(imdb_id, type)
    return nil if imdb_id.blank?
    meta_result = TorrentioService.new.metadata(imdb_id, type)
    return nil if meta_result.failure?
    meta_result.data[:poster_url].presence
  rescue StandardError
    nil
  end
end
