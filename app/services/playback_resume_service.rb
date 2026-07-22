# frozen_string_literal: true

class PlaybackResumeService
  def initialize(user, logger: Rails.logger)
    @user = user
    @logger = logger
  end

  def call(imdb_id:, type:)
    target = type == "movie" ? movie_target(imdb_id) : show_target(imdb_id)
    ServiceResult.success(target)
  rescue StandardError => e
    @logger.error("[PlaybackResumeService] resume target failed: #{e.class}: #{e.message}")
    ServiceResult.failure("Unable to determine playback position")
  end

  private

  def movie_target(imdb_id)
    last = @user.watch_history_entries.where(imdb_id: imdb_id).order(watched_at: :desc).first
    return base_target(season: 0, episode: 0) unless last

    base_target(
      season: 0,
      episode: 0,
      resume_at: PlaybackCompletionPolicy.movie_finished?(last) ? 0 : last.progress_seconds,
      title: last.title,
      poster_url: last.poster_url,
      duration_seconds: last.duration_seconds
    )
  end

  def show_target(imdb_id)
    last = @user.episode_progresses.for_show(imdb_id).recently_watched.first
    return base_target(season: 1, episode: 1) unless last
    return current_episode_target(last) unless PlaybackCompletionPolicy.episode_finished?(last)

    next_episode_target(imdb_id, last)
  end

  def next_episode_target(imdb_id, last)
    next_episode = ProgressTrackingService.next_episode(
      @user,
      imdb_id,
      last.season_number,
      last.episode_number
    )

    if next_episode.success?
      return base_target(
        season: next_episode.data[:season],
        episode: next_episode.data[:episode],
        title: last.show_title
      )
    end

    base_target(
      season: last.season_number,
      episode: last.episode_number,
      title: last.show_title,
      duration_seconds: last.duration_seconds,
      series_complete: next_episode.error_code == :series_complete
    )
  end

  def current_episode_target(last)
    base_target(
      season: last.season_number,
      episode: last.episode_number,
      resume_at: last.progress_seconds,
      title: last.show_title,
      duration_seconds: last.duration_seconds
    )
  end

  def base_target(season:, episode:, resume_at: 0, title: nil, poster_url: nil, duration_seconds: 0, series_complete: false)
    {
      season: season,
      episode: episode,
      resume_at: resume_at,
      title: title,
      poster_url: poster_url,
      duration_seconds: duration_seconds.to_i,
      series_complete: series_complete
    }
  end
end
