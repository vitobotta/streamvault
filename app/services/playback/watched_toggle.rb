# frozen_string_literal: true

module Playback
  # Applies an explicit watched/unwatched decision from the title page.
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
      result = @catalog.metadata(content_ref.imdb_id, "show", include_ratings: false)
      return ServiceResult.failure("Could not load the episode list for this series") if result.failure?

      show = result.data
      episodes = Array(show[:episodes])
        .select { |episode| episode[:season].to_i.positive? && released?(episode) }
        .sort_by { |episode| [ episode[:season].to_i, episode[:episode].to_i ] }
      return ServiceResult.failure("No released episodes found for this series") if episodes.empty?

      show_title = title.presence || show[:title].presence || "Unknown"
      show_poster = poster_url.presence || show[:poster_url]
      watched_at = Time.current

      entries = PlaybackProgress.transaction do
        episodes.map do |episode|
          duration = episode[:runtime_seconds].to_i
          entry = @user.playback_progresses.find_or_initialize_by(
            imdb_id: content_ref.imdb_id,
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

    def mark_series_unwatched(content_ref)
      deleted = @user.playback_progresses.for_show(content_ref.imdb_id).delete_all
      ServiceResult.success(deleted)
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
