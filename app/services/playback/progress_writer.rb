# frozen_string_literal: true

module Playback
  class ProgressWriter
    def initialize(user, catalog: Catalog::CinemetaClient.new, logger: Rails.logger)
      @user = user
      @catalog = catalog
      @logger = logger
    end

    def call(content_ref:, progress_seconds:, duration_seconds:, title: nil, poster_url: nil)
      progress = progress_seconds.to_i
      duration = duration_seconds.to_i
      return ServiceResult.failure("Invalid progress data") unless progress.positive?

      is_new = false
      entry = @user.playback_progresses.find_or_initialize_by(
        imdb_id: content_ref.imdb_id,
        content_type: content_ref.show? ? :episode : :movie,
        season_number: content_ref.season || 0,
        episode_number: content_ref.episode || 0
      ) { is_new = true }
      entry.assign_attributes(
        title: title.presence || stored_title(content_ref) || "Unknown",
        poster_url: poster_url.presence || stored_poster(content_ref),
        watched_at: Time.current,
        progress_seconds: progress,
        duration_seconds: duration
      )
      entry.save!
      RefreshRecommendationsJob.enqueue_debounced(@user.id) if is_new
      ServiceResult.success(entry)
    rescue ActiveRecord::RecordInvalid => e
      ServiceResult.failure(e.message)
    rescue StandardError => e
      @logger.error("[Playback::ProgressWriter] #{e.class}: #{e.message}")
      ServiceResult.failure("Failed to save progress")
    end

    private

    def collection_entry(content_ref)
      @user.collection_entries.find_by(imdb_id: content_ref.imdb_id)
    end

    def stored_title(content_ref)
      collection_entry(content_ref)&.title
    end

    def stored_poster(content_ref)
      collection_entry(content_ref)&.poster_url || metadata(content_ref)&.dig(:poster_url)
    end

    def metadata(content_ref)
      result = @catalog.metadata(content_ref.imdb_id, content_ref.type)
      result.data if result.success?
    rescue StandardError
      nil
    end
  end
end
