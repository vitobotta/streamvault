# frozen_string_literal: true

namespace :series do
  desc "Backfill persisted released-episode totals for library shows missing one"
  task backfill_totals: :environment do
    entries = CollectionEntry.shows.library.where(series_total_episodes: nil)
    count = entries.count
    puts "Backfilling series totals for #{count} library #{count == 1 ? 'show' : 'shows'}..."

    result = Playback::SeriesTotalBackfill.new.call(entries)

    puts "Updated #{result.updated}, skipped #{result.skipped}, failed #{result.failed}."
    puts "Failed IMDb IDs: #{result.failed_ids.join(', ')}" if result.failed_ids.any?
  end
end
