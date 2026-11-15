# frozen_string_literal: true

module Playback
  # Fills persisted released-episode totals for library shows that predate the
  # collection-entry totals. Failures leave the entry untouched so a later run
  # can retry it.
  class SeriesTotalBackfill
    Result = Struct.new(:updated, :skipped, :failed, :failed_ids, keyword_init: true)

    def initialize(catalog: Catalog::CinemetaClient.new, logger: Rails.logger)
      @catalog = catalog
      @logger = logger
    end

    def call(entries)
      result = Result.new(updated: 0, skipped: 0, failed: 0, failed_ids: [])

      entries.find_each do |entry|
        if entry.show?
          sync(entry, result)
        else
          result.skipped += 1
        end
      end

      result
    end

    private

    def sync(entry, result)
      metadata = @catalog.metadata(entry.imdb_id, "show", include_ratings: false)
      unless metadata.success?
        result.failed += 1
        result.failed_ids << entry.imdb_id
        return
      end

      total = SeriesProgress.new(metadata.data[:episodes], finished: {}).total_episodes
      entry.update_columns(
        series_total_episodes: total,
        series_total_episodes_synced_at: Time.current
      )
      result.updated += 1
    rescue StandardError => e
      @logger.warn("[Playback::SeriesTotalBackfill] #{entry.imdb_id}: #{e.class}: #{e.message}")
      result.failed += 1
      result.failed_ids << entry.imdb_id
    end
  end
end
