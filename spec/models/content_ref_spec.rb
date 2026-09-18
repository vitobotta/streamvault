require "rails_helper"

RSpec.describe ContentRef do
  it "preserves a catalogue episode zero through serialization" do
    ref = described_class.new(imdb_id: "tt0073965", type: "show", season: "2", episode: "0")

    expect(ref).to be_episode
    expect(ref.to_h).to eq(imdb_id: "tt0073965", type: "show", season: 2, episode: 0)
    expect(described_class.from_h(ref.to_h)).to eq(ref)
  end

  it "continues to accept ordinary episodes" do
    ref = described_class.new(imdb_id: "tt0073965", type: "show", season: 2, episode: 1)

    expect(ref).to be_episode
    expect(ref.episode).to eq(1)
  end

  [ [ 0, 1 ], [ -1, 1 ], [ 2, -1 ] ].each do |season, episode|
    it "rejects season #{season}, episode #{episode}" do
      expect {
        described_class.new(imdb_id: "tt0073965", type: "show", season: season, episode: episode)
      }.to raise_error(ArgumentError)
    end
  end

  it "still requires season and episode together" do
    expect {
      described_class.new(imdb_id: "tt0073965", type: "show", episode: 0)
    }.to raise_error(ArgumentError, "season and episode must be provided together")
  end

  it "does not interpret an episode-free show as episode zero" do
    ref = described_class.new(imdb_id: "tt0073965", type: "show")

    expect(ref).not_to be_episode
    expect(ref.season).to be_nil
    expect(ref.episode).to be_nil
  end

  it "does not allow episode zero on a movie" do
    expect {
      described_class.new(imdb_id: "tt0073965", type: "movie", season: 2, episode: 0)
    }.to raise_error(ArgumentError, "movies cannot have an episode")
  end
end
