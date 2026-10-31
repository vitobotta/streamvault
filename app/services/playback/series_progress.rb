# frozen_string_literal: true

module Playback
  # Counts watched progress across a series using only episodes that have
  # already aired. Specials (season 0) and unreleased episodes are excluded,
  # matching the series and season watched actions.
  class SeriesProgress
    def initialize(episodes, finished:)
      @episodes = Array(episodes).select { |episode| released?(episode) }
      @finished = finished
    end

    def seasons
      @seasons ||= @episodes.group_by { |episode| episode[:season].to_i }.transform_values do |episodes|
        watched = episodes.count { |episode| @finished[key(episode)] }
        { watched: watched, total: episodes.size }
      end
    end

    def watched_episodes
      seasons.values.sum { |season| season[:watched] }
    end

    def total_episodes
      seasons.values.sum { |season| season[:total] }
    end

    def percentage
      return 0 unless total_episodes.positive?

      ((watched_episodes.to_f / total_episodes) * 100).round
    end

    def complete?
      total_episodes.positive? && watched_episodes == total_episodes
    end

    def summary
      {
        watched: watched_episodes,
        total: total_episodes,
        percentage: percentage,
        complete: complete?
      }
    end

    private

    def key(episode)
      [ episode[:season].to_i, episode[:episode].to_i ]
    end

    def released?(episode)
      return false unless episode[:season].to_i.positive?
      return true if episode[:released].blank?

      Date.parse(episode[:released].to_s) <= Date.current
    rescue ArgumentError
      true
    end
  end
end
