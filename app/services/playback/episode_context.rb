# frozen_string_literal: true

module Playback
  # Resolves the catalogue-side facts for a single episode so callers can build
  # the canonical label without repeating the lookup logic.  The catalogue
  # client caches metadata responses, so a page that already rendered the
  # episode list will not trigger another network round trip.
  class EpisodeContext
    def initialize(catalog: Catalog::CinemetaClient.new, logger: Rails.logger)
      @catalog = catalog
      @logger = logger
    end

    def call(imdb_id:, season:, episode:)
      return ServiceResult.failure("A season and episode are required") if season.blank? || episode.blank?

      metadata = @catalog.metadata(imdb_id, "show", include_ratings: false)
      return ServiceResult.failure(metadata.error_message || "Could not load the episode list") if metadata.failure?

      entry = Array(metadata.data[:episodes]).find do |candidate|
        candidate[:season].to_i == season.to_i && candidate[:episode].to_i == episode.to_i
      end
      return ServiceResult.failure("Episode not found") unless entry

      ServiceResult.success(
        show_title: metadata.data[:title],
        title: entry[:title],
        label: Playback::EpisodeLabel.build(
          show_title: metadata.data[:title],
          season: entry[:season],
          episode: entry[:episode],
          episode_title: entry[:title]
        ),
        duration_seconds: entry[:runtime_seconds]
      )
    rescue StandardError => e
      @logger.warn("[Playback::EpisodeContext] lookup failed: #{e.class}: #{e.message}")
      ServiceResult.failure("Could not load episode details")
    end
  end
end
