# frozen_string_literal: true

module Playback
  class ContinueWatchingQuery
    LIMIT = 20

    def initialize(user, episode_sequence: EpisodeSequence.new)
      @user = user
      @episode_sequence = episode_sequence
    end

    def call
      entries = (unfinished_movies + latest_show_episodes)
        .sort_by { |entry| [ entry.watched_at, entry.id ] }
        .reverse
      ServiceResult.success(entries.filter_map { |entry| item(entry) }.first(LIMIT))
    rescue StandardError => e
      Rails.logger.error("[Playback::ContinueWatchingQuery] #{e.class}: #{e.message}")
      ServiceResult.failure("Unable to load continue watching")
    end

    private

    def unfinished_movies
      @user.playback_progresses.movies_only
        .where("duration_seconds <= 0 OR progress_seconds * 100 < duration_seconds * ?", PlaybackCompletionPolicy::MOVIE_PERCENTAGE)
        .recently_watched.limit(LIMIT).to_a
    end

    def latest_show_episodes
      ranked = @user.playback_progresses.episodes_only.select(
        "playback_progresses.*, ROW_NUMBER() OVER (" \
        "PARTITION BY imdb_id ORDER BY watched_at DESC, id DESC) AS show_watch_rank"
      )
      PlaybackProgress.from("(#{ranked.to_sql}) playback_progresses")
        .where("show_watch_rank = 1").to_a
    end

    def item(entry)
      content_ref = ContentRef.new(
        imdb_id: entry.imdb_id,
        type: entry.episode? ? "show" : "movie",
        season: entry.episode? ? entry.season_number : nil,
        episode: entry.episode? ? entry.episode_number : nil
      )
      progress = entry.progress_seconds
      duration = entry.duration_seconds

      if entry.episode? && PlaybackCompletionPolicy.episode_finished?(entry)
        following = @episode_sequence.next_after(content_ref)
        return if following.error_code == :series_complete
        if following.success?
          content_ref = following.data
          progress = 0
          duration = 0
        end
      end

      {
        imdb_id: content_ref.imdb_id,
        title: entry.title,
        poster_url: entry.poster_url,
        content_type: entry.content_type,
        season: content_ref.season,
        episode: content_ref.episode,
        progress_seconds: progress,
        duration_seconds: duration,
        progress_percentage: percentage(progress, duration),
        last_watched: entry.watched_at,
        history_id: entry.id
      }
    end

    def percentage(progress, duration)
      return progress.positive? ? 1 : 0 unless duration.positive?

      ((progress.to_f / duration) * 100).round.clamp(0, 100)
    end
  end
end
