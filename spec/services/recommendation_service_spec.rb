require 'rails_helper'

RSpec.describe RecommendationService, type: :service do
  let(:user) { create(:user) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    previous = ENV["TMDB_READ_ACCESS_TOKEN"]
    example.run
  ensure
    ENV["TMDB_READ_ACCESS_TOKEN"] = previous
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache)
  end

  it "caches an empty result when TMDB is not configured" do
    ENV["TMDB_READ_ACCESS_TOKEN"] = nil

    expect(described_class.refresh(user).data).to eq([])
    expect(described_class.for(user).data).to eq([])
  end

  it "excludes watched and collected content from refreshed recommendations" do
    ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
    create(:playback_progress, user: user, imdb_id: "tt1375666")
    create(:collection_entry, user: user, imdb_id: "tt0468569")
    allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id)
      .and_return(ServiceResult.success([
        { tmdb_id: 497, imdb_id: "tt0468569", title: "Collected", type: "movie" },
        { tmdb_id: 100, imdb_id: "tt0000123", title: "New", type: "movie" }
      ]))

    result = described_class.refresh(user)

    expect(result.data.map { |item| item[:imdb_id] }).to eq([ "tt0000123" ])
    expect(described_class.for(user).data).to eq(result.data)
  end

  it "filters newly watched content from an existing cache entry" do
    cache.write("recommendations/user/#{user.id}", [
      { tmdb_id: 100, imdb_id: "tt0000123", title: "Cached", type: "movie" }
    ])
    create(:playback_progress, user: user, imdb_id: "tt0000123")

    expect(described_class.for(user).data).to be_empty
  end

  it "uses twenty distinct recent titles as TMDB seeds" do
    ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
    10.times do |episode|
      create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
        season_number: 1, episode_number: episode + 1, watched_at: episode.minutes.ago)
    end
    20.times do |index|
      create(:playback_progress, user: user,
        imdb_id: "tt#{(index + 1).to_s.rjust(7, '0')}",
        watched_at: (index + 20).minutes.ago)
    end
    calls = []
    allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id) do |_service, imdb_id, limit:|
      calls << [ imdb_id, limit ]
      ServiceResult.success([])
    end

    described_class.refresh(user)

    expect(calls.length).to eq(20)
    expect(calls.map(&:first).uniq.length).to eq(20)
    expect(calls).to include([ "tt0903747", 5 ])
  end

  it "contains provider failures and caches an empty result" do
    ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
    create(:playback_progress, user: user, imdb_id: "tt1375666")
    allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id)
      .and_raise(StandardError, "boom")

    expect(described_class.refresh(user).data).to be_empty
    expect(described_class.for(user).data).to be_empty
  end
end
