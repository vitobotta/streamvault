require 'rails_helper'

RSpec.describe Playback::ProgressWriter do
  let(:user) { create(:user) }
  let(:catalog) { instance_double(Catalog::CinemetaClient) }
  let(:movie) { ContentRef.new(imdb_id: "tt1375666", type: "movie") }
  let(:episode) { ContentRef.new(imdb_id: "tt0903747", type: "show", season: 1, episode: 1) }
  subject(:writer) { described_class.new(user, catalog: catalog) }

  before do
    allow(catalog).to receive(:metadata).and_return(
      ServiceResult.success(title: "Catalog title", poster_url: "https://img.example/catalog.jpg")
    )
    allow(RefreshRecommendationsJob).to receive(:enqueue_debounced)
  end

  it "creates and updates one movie progress row" do
    writer.call(content_ref: movie, progress_seconds: 1_800, duration_seconds: 7_200, title: "Inception")
    result = writer.call(content_ref: movie, progress_seconds: 3_600, duration_seconds: 7_200, title: "Inception")

    expect(result).to be_success
    expect(user.playback_progresses.count).to eq(1)
    expect(result.data.progress_percentage).to eq(50)
    expect(RefreshRecommendationsJob).to have_received(:enqueue_debounced).once
  end

  it "keeps separate episode rows in the same show" do
    writer.call(content_ref: episode, progress_seconds: 600, duration_seconds: 2_400, title: "Breaking Bad")
    second = ContentRef.new(imdb_id: episode.imdb_id, type: "show", season: 1, episode: 2)
    writer.call(content_ref: second, progress_seconds: 300, duration_seconds: 2_400, title: "Breaking Bad")

    expect(user.playback_progresses.episodes_only.count).to eq(2)
  end

  it "uses collection metadata before catalog metadata" do
    create(:collection_entry, :wishlist, user: user, imdb_id: movie.imdb_id, title: "Stored title",
      poster_url: "https://img.example/stored.jpg")

    result = writer.call(content_ref: movie, progress_seconds: 60, duration_seconds: 120)

    expect(result.data.title).to eq("Stored title")
    expect(result.data.poster_url).to eq("https://img.example/stored.jpg")
    expect(catalog).not_to have_received(:metadata)
  end

  it "rejects progress that has not started" do
    expect(writer.call(content_ref: movie, progress_seconds: 0, duration_seconds: 120)).to be_failure
  end
end

RSpec.describe Playback::EpisodeSequence do
  let(:catalog) { instance_double(Catalog::CinemetaClient) }
  subject(:sequence) { described_class.new(catalog: catalog) }

  before do
    allow(catalog).to receive(:metadata).and_return(ServiceResult.success(
      episodes: [
        { season: 1, episode: 1 },
        { season: 1, episode: 2 },
        { season: 2, episode: 1 }
      ]
    ))
  end

  it "crosses season boundaries in catalog order" do
    current = ContentRef.new(imdb_id: "tt0903747", type: "show", season: 1, episode: 2)

    expect(sequence.next_after(current).data.to_h).to include(season: 2, episode: 1)
  end

  it "reports series completion at the finale" do
    finale = ContentRef.new(imdb_id: "tt0903747", type: "show", season: 2, episode: 1)

    expect(sequence.next_after(finale).error_code).to eq(:series_complete)
  end
end

RSpec.describe Playback::ContinueWatchingQuery do
  let(:user) { create(:user) }
  let(:episode_sequence) { instance_double(Playback::EpisodeSequence) }
  subject(:query) { described_class.new(user, episode_sequence: episode_sequence) }

  it "keeps movie items free of episode coordinates" do
    create(:playback_progress, :movie, user: user, imdb_id: "tt1375666",
      progress_seconds: 3_000, duration_seconds: 7_200)

    item = query.call.data.first

    expect(item.slice(:content_type, :season, :episode)).to eq(
      content_type: "movie",
      season: nil,
      episode: nil
    )
  end

  it "keeps the current episode below the exact completion threshold" do
    create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
      progress_seconds: 2_340, duration_seconds: 2_400)

    item = query.call.data.first

    expect(item.slice(:season, :episode, :progress_seconds)).to eq(season: 1, episode: 1, progress_seconds: 2_340)
  end

  it "advances a completed episode" do
    create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
      progress_seconds: 2_352, duration_seconds: 2_400)
    next_ref = ContentRef.new(imdb_id: "tt0903747", type: "show", season: 1, episode: 2)
    allow(episode_sequence).to receive(:next_after).and_return(ServiceResult.success(next_ref))

    item = query.call.data.first

    expect(item.slice(:season, :episode, :progress_seconds)).to eq(season: 1, episode: 2, progress_seconds: 0)
  end

  it "removes only a completed series finale" do
    create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
      progress_seconds: 2_400, duration_seconds: 2_400)
    allow(episode_sequence).to receive(:next_after)
      .and_return(ServiceResult.failure("No more episodes", :series_complete))

    expect(query.call.data).to be_empty
  end
end
