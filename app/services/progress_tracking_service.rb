# frozen_string_literal: true

class ProgressTrackingService
  # Save watch progress for content
  def self.save_progress(user, imdb_id, progress_seconds, duration_seconds, type:, season: nil, episode: nil)
    return ServiceResult.failure("Invalid progress data") if progress_seconds.blank? || duration_seconds.blank?

    progress_pct = duration_seconds.positive? ? ((progress_seconds.to_f / duration_seconds) * 100).round : 0

    # Create watch history entry
    entry = user.watch_history_entries.create!(
      content_type: type == "show" ? :episode : :movie,
      imdb_id: imdb_id,
      title: fetch_title(user, imdb_id, type),
      poster_url: fetch_poster(user, imdb_id, type),
      season_number: season,
      episode_number: episode,
      show_imdb_id: type == "show" ? imdb_id : nil,
      show_title: type == "show" ? fetch_title(user, imdb_id, type) : nil,
      watched_at: Time.current,
      progress_seconds: progress_seconds,
      duration_seconds: duration_seconds,
      progress_percentage: progress_pct
    )

    # Update episode progress for shows
    if type == "show" && season && episode
      update_episode_progress(user, imdb_id, season, episode, progress_seconds, duration_seconds)
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
    # Check if there's a next episode
    next_episode = episode + 1

    # Check if next episode exists in progress tracking
    exists = user.episode_progresses.exists?(
      show_imdb_id: show_imdb_id,
      season_number: season,
      episode_number: next_episode
    )

    if exists
      ServiceResult.success({
        season: season,
        episode: next_episode,
        exists: true
      })
    else
      # Try next season
      next_season = season + 1
      season_exists = user.episode_progresses.exists?(
        show_imdb_id: show_imdb_id,
        season_number: next_season,
        episode_number: 1
      )

      if season_exists
        ServiceResult.success({
          season: next_season,
          episode: 1,
          exists: true
        })
      else
        ServiceResult.success({
          season: nil,
          episode: nil,
          exists: false
        })
      end
    end
  end

  # Get continue watching list
  def self.continue_watching(user)
    # Get latest watch history entries that aren't finished
    recent = user.watch_history_entries
      .where("progress_percentage < ?", 90)
      .order(watched_at: :desc)
      .limit(20)

    # Group by content and get the latest per content
    grouped = recent.group_by { |e| [e.imdb_id, e.show_imdb_id].compact.first }
    items = grouped.map do |_key, entries|
      latest = entries.first
      {
        imdb_id: latest.show_imdb_id || latest.imdb_id,
        title: latest.show_title || latest.title,
        poster_url: latest.poster_url,
        content_type: latest.content_type,
        season: latest.season_number,
        episode: latest.episode_number,
        progress_seconds: latest.progress_seconds,
        duration_seconds: latest.duration_seconds,
        progress_percentage: latest.progress_percentage,
        last_watched: latest.watched_at
      }
    end

    ServiceResult.success(items.sort_by { |i| -i[:last_watched].to_i })
  end

  private

  def self.update_episode_progress(user, show_imdb_id, season, episode, progress_seconds, duration_seconds)
    ep = user.episode_progresses.find_or_initialize_by(
      show_imdb_id: show_imdb_id,
      season_number: season,
      episode_number: episode
    )

    ep.update!(
      show_title: fetch_title(user, show_imdb_id, "show"),
      progress_seconds: progress_seconds,
      duration_seconds: duration_seconds,
      last_watched_at: Time.current
    )
  end

  def self.update_library_watch_status(user, imdb_id, type, progress_pct)
    entry = user.library_entries.find_by(imdb_id: imdb_id)
    return unless entry

    new_status = if progress_pct >= 90
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
    user.library_entries.find_by(imdb_id: imdb_id)&.poster_url
  end
end
