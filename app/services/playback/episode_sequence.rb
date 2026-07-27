# frozen_string_literal: true

module Playback
  class EpisodeSequence
    def initialize(catalog: Catalog::CinemetaClient.new, logger: Rails.logger)
      @catalog = catalog
      @logger = logger
    end

    def next_after(content_ref)
      result = @catalog.metadata(content_ref.imdb_id, "show")
      return ServiceResult.failure("Could not load episode list") if result.failure?

      episodes = Array(result.data[:episodes])
        .reject { |episode| episode[:season].to_i.zero? }
        .sort_by { |episode| [ episode[:season].to_i, episode[:episode].to_i ] }
      return ServiceResult.failure("No episodes available") if episodes.empty?

      index = episodes.index do |episode|
        episode[:season].to_i == content_ref.season && episode[:episode].to_i == content_ref.episode
      end
      following = index && episodes[index + 1]
      return ServiceResult.failure("No more episodes", :series_complete) unless following

      ServiceResult.success(
        ContentRef.new(
          imdb_id: content_ref.imdb_id,
          type: "show",
          season: following[:season],
          episode: following[:episode]
        )
      )
    rescue StandardError => e
      @logger.error("[Playback::EpisodeSequence] #{e.class}: #{e.message}")
      ServiceResult.failure("Could not determine next episode")
    end
  end
end
