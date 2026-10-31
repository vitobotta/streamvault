require "rails_helper"

RSpec.describe Playback::SeriesTotalBackfill do
  let(:user) { create(:user) }
  let(:catalog) { instance_double(Catalog::CinemetaClient) }

  subject(:service) { described_class.new(catalog: catalog, logger: Rails.logger) }

  def stub_metadata(result)
    allow(catalog).to receive(:metadata)
      .with("tt0903747", "show", include_ratings: false)
      .and_return(result)
  end

  it "persists the released episode total for library shows missing one" do
    entry = create(:collection_entry, :show, user: user, imdb_id: "tt0903747")
    stub_metadata(ServiceResult.success(episodes: [
      { season: 0, episode: 1, released: "2008-01-01" },
      { season: 1, episode: 1, released: "2008-01-20" },
      { season: 1, episode: 2, released: "2008-01-27" },
      { season: 2, episode: 1, released: Date.tomorrow.iso8601 }
    ]))

    result = service.call(CollectionEntry.shows.library.where(series_total_episodes: nil))

    expect(result.updated).to eq(1)
    expect(result.failed).to eq(0)
    expect(entry.reload.series_total_episodes).to eq(2)
    expect(entry.series_total_episodes_synced_at).to be_present
  end

  it "leaves entries untouched when metadata cannot be loaded" do
    entry = create(:collection_entry, :show, user: user, imdb_id: "tt0903747")
    stub_metadata(ServiceResult.failure("Unavailable"))

    result = service.call(CollectionEntry.shows.library.where(series_total_episodes: nil))

    expect(result.updated).to eq(0)
    expect(result.failed).to eq(1)
    expect(result.failed_ids).to contain_exactly("tt0903747")
    expect(entry.reload.series_total_episodes).to be_nil
    expect(entry.series_total_episodes_synced_at).to be_nil
  end
end
