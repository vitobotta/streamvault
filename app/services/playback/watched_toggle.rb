# frozen_string_literal: true

module Playback
  # Applies an explicit watched/unwatched decision from the title page, a
  # library card, or a watch-history row.
  #
  # "Watched" is stored as an authoritative completed flag rather than a
  # percentage, because catalogue metadata sometimes has no runtime.  Playback
  # progress writes clear the flag again, so resuming a manually-watched title
  # behaves normally.
  class WatchedToggle
    MAX_DURATION_SECONDS = 24 * 60 * 60

    def initialize(user, catalog: Catalog::CinemetaClient.new, logger: Rails.logger)
      @user = user
      @catalog = catalog
      @logger = logger
    end

    def call(imdb_id:, type:, watched:, season: nil, episode: nil,
             title: nil, poster_url: nil, duration_seconds: nil)
      if season_level?(type, season, episode)
        return mark_season(imdb_id, season, watched: watched, title: title, poster_url: poster_url)
      end

      content_ref = ContentRef.new(imdb_id: imdb_id, type: type, season: season, episode: episode)
      if content_ref.show? && !content_ref.episode?
        return mark_series_watched(content_ref, title: title, poster_url: poster_url) if watched

        return mark_series_unwatched(content_ref)
      end

      entry = find_entry(content_ref)

      return mark_watched(content_ref, entry, title: title, poster_url: poster_url,
                          duration_seconds: duration_seconds) if watched

      mark_unwatched(entry)
    rescue ArgumentError => e
      ServiceResult.failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      ServiceResult.failure(e.record.errors.full_messages.to_sentence)
    rescue StandardError => e
      @logger.error("[Playback::WatchedToggle] #{e.class}: #{e.message}")
      ServiceResult.failure("Unable to update watched state")
    end

    private

    # A season is addressed as show + season without an episode.  ContentRef
    # deliberately requires the pair, so season actions are validated here
    # before they reach it.
    def season_level?(type, season, episode)
      type.to_s == "show" && season.present? && episode.blank?
    end

    def mark_season(imdb_id, season, watched:, title:, poster_url:)
      return ServiceResult.failure("Invalid content ID") unless ContentRef::IMDB_ID_PATTERN.match?(imdb_id.to_s)

      season_number = Integer(season, exception: false)
      return ServiceResult.failure("Season must be positive") unless season_number&.positive?
      return mark_season_unwatched(imdb_id, season_number) unless watched

      show, failure = load_show(imdb_id)
      return failure if failure

      episodes = released_episodes(show).select { |episode| episode[:season].to_i == season_number }
      return ServiceResult.failure("No released episodes found for this season") if episodes.empty?

      persist_episodes(imdb_id, episodes, show: show, title: title, poster_url: poster_url)
    end

    def find_entry(content_ref)
      @user.playback_progresses.find_by(
        imdb_id: content_ref.imdb_id,
        content_type: content_ref.show? ? :episode : :movie,
        season_number: content_ref.show? ? content_ref.season : 0,
        episode_number: content_ref.show? ? content_ref.episode : 0
      )
    end

    def mark_watched(content_ref, entry, title:, poster_url:, duration_seconds:)
      duration = duration_for(entry, duration_seconds)
      entry ||= @user.playback_progresses.new(
        imdb_id: content_ref.imdb_id,
        content_type: content_ref.show? ? :episode : :movie,
        season_number: content_ref.season || 0,
        episode_number: content_ref.episode || 0
      )

      entry.assign_attributes(
        title: title.presence || entry.title.presence || "Unknown",
        poster_url: poster_url.presence || entry.poster_url,
        watched_at: Time.current,
        progress_seconds: duration,
        duration_seconds: duration,
        completed: true
      )
      entry.save!
      ServiceResult.success(entry)
    end

    # A series has no single play position, so its watched state is derived
    # from its released episodes. Specials and episodes that have not aired
    # yet are left alone.
    def mark_series_watched(content_ref, title:, poster_url:)
      show, failure = load_show(content_ref.imdb_id)
      return failure if failure

      episodes = released_episodes(show)
      return ServiceResult.failure("No released episodes found for this series") if episodes.empty?

      persist_episodes(content_ref.imdb_id, episodes, show: show, title: title, poster_url: poster_url)
    end

    def mark_series_unwatched(content_ref)
      deleted = @user.playback_progresses.for_show(content_ref.imdb_id).delete_all
      ServiceResult.success(deleted)
    end

    def mark_season_unwatched(imdb_id, season_number)
      deleted = @user.playback_progresses.episodes_only
        .where(imdb_id: imdb_id, season_number: season_number)
        .delete_all
      ServiceResult.success(deleted)
    end

    def load_show(imdb_id)
      result = @catalog.metadata(imdb_id, "show", include_ratings: false)
      return [ nil, ServiceResult.failure("Could not load the episode list for this show") ] if result.failure?

      [ result.data, nil ]
    end

    def released_episodes(show)
      Array(show[:episodes])
        .select { |episode| episode[:season].to_i.positive? && released?(episode) }
        .sort_by { |episode| [ episode[:season].to_i, episode[:episode].to_i ] }
    end

    def persist_episodes(imdb_id, episodes, show:, title:, poster_url:)
      show_title = title.presence || show[:title].presence || "Unknown"
      show_poster = poster_url.presence || show[:poster_url]
      watched_at = Time.current

      entries = PlaybackProgress.transaction do
        episodes.map do |episode|
          duration = episode[:runtime_seconds].to_i
          entry = @user.playback_progresses.find_or_initialize_by(
            imdb_id: imdb_id,
            content_type: :episode,
            season_number: episode[:season].to_i,
            episode_number: episode[:episode].to_i
          )
          entry.update!(
            title: episode_title(show_title, episode),
            poster_url: show_poster,
            watched_at: watched_at,
            progress_seconds: duration,
            duration_seconds: duration,
            completed: true
          )
          entry
        end
      end

      ServiceResult.success(entries.size)
    end

    # Unwatched removes the local progress row for this title (or this one
    # episode), which also clears it from Continue Watching and Watch History.
    # Other episodes of the same show are untouched.
    def mark_unwatched(entry)
      entry&.destroy!
      ServiceResult.success(entry)
    end

    def episode_title(show_title, episode)
      "#{show_title} S#{format('%02d', episode[:season].to_i)}E#{format('%02d', episode[:episode].to_i)}"
    end

    def released?(episode)
      release_date = episode[:released]
      return true if release_date.blank?

      Date.parse(release_date.to_s) <= Date.current
    rescue ArgumentError
      true
    end

    def duration_for(entry, duration_seconds)
      provided = duration_seconds.to_i
      return provided if provided.positive? && provided <= MAX_DURATION_SECONDS

      entry&.duration_seconds.to_i.positive? ? entry.duration_seconds.to_i : 0
    end
  end
end
