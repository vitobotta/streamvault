# frozen_string_literal: true

class ProgressTrackingService
  MOVIE_COMPLETION_PERCENTAGE = 95

  # Save watch progress for content
  def self.save_progress(user, imdb_id, progress_seconds, duration_seconds, type:, season: nil, episode: nil, poster_url: nil, title: nil)
    progress_seconds = progress_seconds.to_i
    duration_seconds = duration_seconds.to_i
    return ServiceResult.failure("Invalid progress data") unless progress_seconds.positive?

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

    is_new_entry = false
    entry = user.watch_history_entries.find_or_initialize_by(
      content_type: content_type_val,
      imdb_id: imdb_id,
      show_imdb_id: show_imdb_val,
      season_number: season_val,
      episode_number: episode_val
    ) do |e|
      is_new_entry = true
    end
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

    # Refresh recommendations only when the user starts watching
    # new content (not on every 5s progress tick).  Debounced to max
    # one job per 10 minutes per user.
    RefreshRecommendationsJob.enqueue_debounced(user.id) if is_new_entry

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
      ServiceResult.failure("No more episodes", :series_complete)
    end
  rescue StandardError => e
    Rails.logger.error("ProgressTrackingService#next_episode error: #{e.message}")
    ServiceResult.failure("Could not determine next episode")
  end

  # Get Continue Watching — one item per movie or show. Movies disappear
  # at the existing completion threshold. Shows remain after a completed
  # episode when another episode exists, and point at that next episode.
  def self.continue_watching(user)
    movies = user.watch_history_entries
      .movies_only
      .where("progress_percentage < ?", MOVIE_COMPLETION_PERCENTAGE)
      .recently_watched
      .limit(20)
      .to_a

    # Select only the latest watched episode per show in SQL. This avoids
    # letting a long binge of one show crowd every other show out of the
    # candidate set before we deduplicate.
    ranked_episodes = user.watch_history_entries
      .episodes_only
      .select(
        "watch_history_entries.*, " \
        "ROW_NUMBER() OVER (" \
        "PARTITION BY show_imdb_id " \
        "ORDER BY watched_at DESC, id DESC" \
        ") AS show_watch_rank"
      )
    latest_episodes = WatchHistoryEntry
      .from("(#{ranked_episodes.to_sql}) watch_history_entries")
      .where("show_watch_rank = 1")
      .to_a

    items = (movies + latest_episodes)
      .sort_by { |entry| [ entry.watched_at, entry.id ] }
      .reverse
      .filter_map { |entry| continue_watching_item(user, entry) }

    ServiceResult.success(items.first(20))
  end

  def self.continue_watching_item(user, entry)
    season = entry.season_number
    episode = entry.episode_number
    progress_seconds = entry.progress_seconds
    duration_seconds = entry.duration_seconds
    progress_percentage = entry.progress_percentage
    episode_finished = entry.episode? &&
      entry.duration_seconds.positive? &&
      entry.progress_seconds.fdiv(entry.duration_seconds) >= EpisodeProgress::COMPLETION_RATIO

    if episode_finished
      next_episode = self.next_episode(
        user,
        entry.show_imdb_id,
        entry.season_number,
        entry.episode_number
      )
      return if next_episode.error_code == :series_complete

      if next_episode.success?
        season = next_episode.data[:season]
        episode = next_episode.data[:episode]
        progress_seconds = 0
        duration_seconds = 0
        progress_percentage = 0
      end
    end

    {
      imdb_id: entry.show_imdb_id.presence || entry.imdb_id,
      title: entry.show_title.presence || entry.title,
      poster_url: entry.poster_url,
      content_type: entry.content_type,
      season: season,
      episode: episode,
      progress_seconds: progress_seconds,
      duration_seconds: duration_seconds,
      progress_percentage: progress_percentage,
      last_watched: entry.watched_at,
      history_id: entry.id
    }
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
