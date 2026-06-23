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

    # Update or create watch history entry (one row per content)
    content_type_val = type == "show" ? :episode : :movie
    season_val = type == "show" ? season : 0
    episode_val = type == "show" ? episode : 0

    entry = user.watch_history_entries.find_or_initialize_by(
      content_type: content_type_val,
      imdb_id: imdb_id,
      season_number: season_val,
      episode_number: episode_val
    )
    entry.update!(
      title: resolved_title,
      poster_url: resolved_poster,
      show_imdb_id: type == "show" ? imdb_id : nil,
      show_title: type == "show" ? resolved_title : nil,
      watched_at: Time.current,
      progress_seconds: progress_seconds,
      duration_seconds: duration_seconds,
      progress_percentage: progress_pct
    )

    # Update episode progress for shows
    if type == "show" && season && episode
      update_episode_progress(user, imdb_id, season, episode, progress_seconds, duration_seconds, resolved_title)
    end

    # Update library entry watch status
    update_library_watch_status(user, imdb_id, type, progress_pct)

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

  # Auto-advance to next episode
  def self.auto_advance(user, show_imdb_id, season, episode)
    next_episode = episode + 1

    exists = user.episode_progresses.exists?(
      show_imdb_id: show_imdb_id,
      season_number: season,
      episode_number: next_episode
    )

    if exists
      ServiceResult.success({ season: season, episode: next_episode, exists: true })
    else
      next_season = season + 1
      season_exists = user.episode_progresses.exists?(
        show_imdb_id: show_imdb_id,
        season_number: next_season,
        episode_number: 1
      )

      if season_exists
        ServiceResult.success({ season: next_season, episode: 1, exists: true })
      else
        ServiceResult.failure("No more episodes")
      end
    end
  end

  # Get continue watching list
  def self.continue_watching(user)
    recent = user.watch_history_entries
      .where("progress_percentage < ?", 95)
      .order(watched_at: :desc)
      .limit(20)

    items = recent.map do |e|
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

    ServiceResult.success(items.sort_by { |i| -i[:last_watched].to_i })
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

  def self.fetch_poster(user, imdb_id, _type)
    user.library_entries.find_by(imdb_id: imdb_id)&.poster_url ||
      user.wishlist_entries.find_by(imdb_id: imdb_id)&.poster_url
  end
end
