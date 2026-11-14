# frozen_string_literal: true

class AddSeriesEpisodeTotalsToCollectionEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :collection_entries, :series_total_episodes, :integer
    add_column :collection_entries, :series_total_episodes_synced_at, :datetime
  end
end
