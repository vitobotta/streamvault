# frozen_string_literal: true

module Streams
  class Ranker
    QUALITY_ORDER = { "4K" => 0, "1080p" => 1, "720p" => 2, "480p" => 3, "Unknown" => 4 }.freeze

    def initialize(default_language:, preferred_languages:)
      @language_priority = normalize_languages([ default_language, *Array(preferred_languages) ])
    end

    def call(streams)
      candidates = streams.map do |stream|
        candidate = StreamCandidate.from(stream)
        candidate.merge(language_score: language_score(candidate))
      end
      candidates.select! { |candidate| accepted_language?(candidate) } if @language_priority.any?
      candidates.sort_by { |candidate| sort_key(candidate) }
    end

    private

    def accepted_language?(candidate)
      languages = normalized_candidate_languages(candidate)
      (languages & @language_priority).any?
    end

    def language_score(candidate)
      return 0 if @language_priority.empty?

      indexes = normalized_candidate_languages(candidate).filter_map { |language| @language_priority.index(language) }
      indexes.min || @language_priority.length
    end

    def normalized_candidate_languages(candidate)
      languages = normalize_languages(candidate.languages)
      languages.presence || [ "ENG" ]
    end

    def normalize_languages(values)
      Array(values).flatten.map(&:to_s).map(&:upcase)
        .select { |language| Streams::ReleaseParser::LANGUAGE_PATTERNS.key?(language) }.uniq
    end

    def sort_key(candidate)
      [
        candidate.language_score,
        -candidate.compatibility_score,
        candidate.rd_plus ? 0 : 1,
        QUALITY_ORDER.fetch(candidate.quality.to_s, QUALITY_ORDER["Unknown"]),
        -candidate.raw_size
      ]
    end
  end
end
