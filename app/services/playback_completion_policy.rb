# frozen_string_literal: true

class PlaybackCompletionPolicy
  MOVIE_PERCENTAGE = 95
  EPISODE_RATIO = 0.98

  def self.movie_finished?(entry_or_percentage)
    percentage = if entry_or_percentage.respond_to?(:progress_percentage)
      entry_or_percentage.progress_percentage
    else
      entry_or_percentage
    end

    percentage.to_i >= MOVIE_PERCENTAGE
  end

  def self.episode_finished?(entry)
    return false unless entry

    duration = entry.duration_seconds.to_i
    duration.positive? && entry.progress_seconds.to_f.fdiv(duration) >= EPISODE_RATIO
  end
end
