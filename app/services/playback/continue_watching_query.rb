# frozen_string_literal: true

module Playback
  class ContinueWatchingQuery
    LIMIT = 20
    RESOLUTION_BATCH = 8

    def initialize(user, episode_sequence: EpisodeSequence.new)
      @user = user
      @episode_sequence = episode_sequence
    end

    def call
      entries = (unfinished_movies + latest_show_episodes)
        .sort_by { |entry| [ entry.watched_at, entry.id ] }
        .reverse
      ServiceResult.success(collect_items(entries))
    rescue StandardError => e
      Rails.logger.error("[Playback::ContinueWatchingQuery] #{e.class}: #{e.message}")
      ServiceResult.failure("Unable to load continue watching")
    end

    private

    # Entries are already in presentation order. Resolving an item can trigger
    # a metadata lookup (finished episodes need their successor), so items are
    # resolved in small concurrent batches and building stops once LIMIT items
    # are collected: the number of lookups is bounded by the visible row, not
    # by the whole watch history.
    def collect_items(entries)
      items = []
      entries.each_slice(RESOLUTION_BATCH) do |batch|
        items.concat(resolve_batch(batch))
        break if items.length >= LIMIT
      end
      items.first(LIMIT)
    end

    def resolve_batch(batch)
      batch.map { |entry| Thread.new { item(entry) } }.filter_map(&:value)
    end

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
      label = entry.title
      show_title = nil
      episode_title = nil

      if entry.episode? && PlaybackCompletionPolicy.episode_finished?(entry)
        following = @episode_sequence.next_episode_after(content_ref)
        return if following.error_code == :series_complete
        if following.success?
          content_ref = following.data.content_ref
          progress = 0
          duration = 0
          # The card must describe the episode the user will actually play,
          # not the one that just finished.
          label = following.data.label.presence || entry.title
          show_title = following.data.show_title
          episode_title = following.data.title
        end
      end

      if entry.episode?
        parts = label_parts(label)
        show_title ||= parts[:show_title]
        episode_title ||= parts[:episode_title]
      end

      {
        imdb_id: content_ref.imdb_id,
        title: show_title.presence || label,
        episode_title: episode_title,
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

    # Splits a canonical "Show · S01E02 · Name" label back into its parts, so
    # cards can render a compact "S01E02 · Name" subtitle without another
    # catalogue lookup.
    def label_parts(label)
      parts = label.to_s.split(Playback::EpisodeLabel::SEPARATOR)
      {
        show_title: parts.first.presence,
        episode_title: parts.length >= 3 ? parts.last.presence : nil
      }
    end

    def percentage(progress, duration)
      return progress.positive? ? 1 : 0 unless duration.positive?

      ((progress.to_f / duration) * 100).round.clamp(0, 100)
    end
  end
end
