require "rails_helper"

# Regression coverage for episode titles failing to reach the player.  Every
# entry point must carry the catalogue label, and the server must never trust a
# stale or missing title from the client.
RSpec.describe "Episode title propagation", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:episodes) do
    [
      { season: 1, episode: 1, title: "Pilot", runtime_seconds: 2_400, released: "2008-01-20" },
      { season: 1, episode: 2, title: "Cat's in the Bag...", runtime_seconds: 2_400, released: "2008-01-27" }
    ]
  end
  let(:metadata) do
    ServiceResult.success(
      title: "Breaking Bad",
      poster_url: "https://img.example.com/show.jpg",
      episodes: episodes
    )
  end
  let(:source) do
    ResolvedSource.new(url: "https://download.real-debrid.com/d/file/episode.mp4", filename: "episode.mp4")
  end
  let(:resolver) { instance_double(Streams::Resolver) }

  before do
    sign_in user
    allow_any_instance_of(Catalog::CinemetaClient).to receive(:metadata)
      .with("tt0903747", "show", include_ratings: false)
      .and_return(metadata)
    allow(Streams::Resolver).to receive(:new).and_return(resolver)
    allow(resolver).to receive(:start).and_return(ServiceResult.success(source: source))
  end

  it "submits the canonical label from the episode drawer" do
    streams = [
      {
        resolve_url: "https://provider.test/resolve/1",
        filename: "episode.mp4",
        quality: "1080p",
        languages: [ "English" ],
        size: "1.2 GB",
        title: "1080p BluRay x264"
      }
    ]
    allow_any_instance_of(AvailableStreamsService).to receive(:call).and_return(ServiceResult.success(streams))

    get episode_streams_path(type: "show", imdb_id: "tt0903747", season: 1, episode: 2)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Breaking Bad · S01E02 · Cat")
    # The old synthetic "Show S01E02" title must not be submitted either.
    expect(response.body).not_to include("Breaking Bad S01E02")
  end

  it "overrides a stale title sent by the client with the catalogue label" do
    post streaming_index_path,
      params: { imdb_id: "tt0903747", type: "show", season: 1, episode: 2, title: "Breaking Bad" }

    expect(response).to have_http_status(:found)
    expect(redirected_playback_descriptor(response, user: user).title)
      .to eq("Breaking Bad · S01E02 · Cat's in the Bag...")
  end

  it "still accepts a client label when the catalogue has no episode entry" do
    allow_any_instance_of(Catalog::CinemetaClient).to receive(:metadata)
      .and_return(ServiceResult.success(title: "Breaking Bad", episodes: []))

    post streaming_index_path,
      params: { imdb_id: "tt0903747", type: "show", season: 9, episode: 9, title: "Breaking Bad · S09E09" }

    expect(redirected_playback_descriptor(response, user: user).title).to eq("Breaking Bad · S09E09")
  end

  it "carries the next episode's label and runtime through auto-advance" do
    token = signed_playback_for(
      user, imdb_id: "tt0903747", type: "show", season: 1, episode: 1,
      title: "Breaking Bad · S01E01 · Pilot"
    )

    get resume_streaming_index_path(after: token)

    expect(response).to have_http_status(:found)
    descriptor = redirected_playback_descriptor(response, user: user)
    expect(descriptor.content_ref.episode).to eq(2)
    expect(descriptor.title).to eq("Breaking Bad · S01E02 · Cat's in the Bag...")
    expect(descriptor.duration).to eq(2_400)
  end

  it "renders the label in the player chrome" do
    token = signed_playback_for(
      user, imdb_id: "tt0903747", type: "show", season: 1, episode: 2,
      title: "Breaking Bad · S01E02 · Cat's in the Bag..."
    )

    get streaming_path("play", playback: token)

    expect(response).to have_http_status(:ok)
    # Episode name is the headline; show + position form the context line.
    expect(response.body).to include("Cat&#39;s in the Bag...")
    expect(response.body).to include("Breaking Bad · S01E02")
  end
end
