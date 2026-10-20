# frozen_string_literal: true

module Playback
  class EpisodeSequence
    # The next episode plus the catalogue facts needed to label and time it.
    # Callers that only need the coordinates should keep using #next_after.
    Next = Struct.new(
      :content_ref, :show_title, :title, :label, :duration_seconds, :released,
      keyword_init: true
    ) do
      def season = content_ref.season
      def episode = content_ref.episode
    end

    def initialize(catalog: Catalog::CinemetaClient.new, logger: Rails.logger)
      @catalog = catalog
      @logger = logger
    end

    # Backwards-compatible shape: success carries the next ContentRef.
    def next_after(content_ref)
      result = next_episode_after(content_ref)
      return result if result.failure?

      ServiceResult.success(result.data.content_ref)
    end

    # Success carries a Next struct, so auto-advance can hand the player the
    # correct episode title instead of inheriting the previous episode's.
    def next_episode_after(content_ref)
      result = @catalog.metadata(content_ref.imdb_id, "show", include_ratings: false)
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
      if following[:released].present? && Date.parse(following[:released].to_s) > Date.current
        return ServiceResult.failure("Next episode has not aired yet", :not_released)
      end

      ServiceResult.success(build_next(content_ref.imdb_id, result.data[:title], following))
    rescue StandardError => e
      @logger.error("[Playback::EpisodeSequence] #{e.class}: #{e.message}")
      ServiceResult.failure("Could not determine next episode")
    end

    private

    def build_next(imdb_id, show_title, episode)
      Next.new(
        content_ref: ContentRef.new(
          imdb_id: imdb_id,
          type: "show",
          season: episode[:season],
          episode: episode[:episode]
        ),
        show_title: show_title,
        title: episode[:title],
        label: Playback::EpisodeLabel.build(
          show_title: show_title,
          season: episode[:season],
          episode: episode[:episode],
          episode_title: episode[:title]
        ),
        duration_seconds: episode[:runtime_seconds],
        released: episode[:released]
      )
    end
  end
end
