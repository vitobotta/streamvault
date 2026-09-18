require "rails_helper"

RSpec.describe "Episode zero playback", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:imdb_id) { "tt0073965" }
  let(:filename) { "The.Bionic.Woman.S02E00.mp4" }
  let(:resolve_url) { "https://torrentio.strem.fun/resolve/realdebrid/test_key/episode-zero/null/0/#{filename}" }
  let(:source_url) { "https://download.real-debrid.com/d/episode-zero/#{filename}" }
  let(:provider_url) { %r{torrentio\.strem\.fun/([^/]+/)?stream/series/tt0073965:2:0\.json} }
  let(:coordinates) { { imdb_id: imdb_id, type: "show", season: "2", episode: "0" } }

  around do |example|
    original = ENV["STREAM_PROVIDER"]
    ENV["STREAM_PROVIDER"] = "torrentio"
    example.run
  ensure
    original.nil? ? ENV.delete("STREAM_PROVIDER") : ENV["STREAM_PROVIDER"] = original
  end

  before do
    sign_in user
    allow(RefreshRecommendationsJob).to receive(:enqueue_debounced)
    stub_request(:get, "https://v3-cinemeta.strem.io/meta/series/#{imdb_id}.json")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
        meta: {
          id: imdb_id, name: "The Bionic Woman",
          videos: [
            { season: 1, episode: 14, name: "Fly Jaime" },
            { season: 2, episode: 0, name: "The Return of Bigfoot (2)", runtime: "48 min" },
            { season: 2, episode: 1, name: "In This Corner, Jaime Sommers" }
          ]
        }
      }.to_json)
    stub_request(:get, provider_url)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
        streams: [ { title: "The Bionic Woman 1080p ENG", url: resolve_url,
                     behaviorHints: { filename: filename } } ]
      }.to_json)
    stub_request(:get, resolve_url).to_return(status: 302, headers: { "Location" => source_url })
  end

  it "starts a manually selected episode zero and renders its signed player" do
    get episode_streams_path(type: "show", imdb_id: imdb_id, season: 2, episode: 0)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="episode" value="0"')

    post streaming_index_path, params: coordinates.merge(resolve_url: resolve_url, filename: filename)

    expect(response).to have_http_status(:found)
    descriptor = redirected_playback_descriptor(response, user: user)
    expect(descriptor.content_ref.to_h).to include(season: 2, episode: 0)
    expect(descriptor.duration).to eq(2_880)
    expect(ResolvedSource.resolve(token: descriptor.source_token, user: user, verify_dns: false).url).to eq(source_url)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-video-player-episode-value="0"')
  end

  it "looks up episode zero without silently renumbering it" do
    post streaming_index_path, params: coordinates

    expect(response).to have_http_status(:found)
    expect(redirected_playback_descriptor(response, user: user).content_ref.episode).to eq(0)
    expect(WebMock).to have_requested(:get, provider_url).once
    expect(WebMock).not_to have_requested(:get, %r{/stream/series/tt0073965:2:1\.json})
  end

  it "saves and resumes episode-zero progress" do
    patch progress_streaming_path("play"), params: coordinates.merge(
      title: "The Bionic Woman", progress_seconds: 120, duration_seconds: 2_880)

    expect(response).to have_http_status(:ok)
    progress = user.playback_progresses.find_by!(imdb_id: imdb_id, season_number: 2, episode_number: 0)
    expect(progress).to be_episode
    expect(progress.progress_seconds).to eq(120)

    get resume_streaming_index_path(type: "show", imdb_id: imdb_id)

    descriptor = redirected_playback_descriptor(response, user: user)
    expect(descriptor.content_ref.to_h).to include(season: 2, episode: 0)
    expect(descriptor.resume_at).to eq(120)
  end

  it "offers and starts episode zero at a season boundary" do
    previous = signed_playback_for(user, imdb_id: imdb_id, type: "show", season: 1, episode: 14)
    get next_episode_streaming_path("play", playback: previous)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("available" => true, "season" => 2, "episode" => 0)
    get response.parsed_body.fetch("url")
    expect(redirected_playback_descriptor(response, user: user).content_ref.to_h).to include(season: 2, episode: 0)
  end

  it "advances from episode zero to episode one" do
    playback = signed_playback_for(user, imdb_id: imdb_id, type: "show", season: 2, episode: 0)
    get next_episode_streaming_path("play", playback: playback)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("available" => true, "season" => 2, "episode" => 1)
  end

  it "continues to reject negative episodes before looking up streams" do
    post streaming_index_path, params: coordinates.merge(episode: "-1")

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to include("episode")
    expect(WebMock).not_to have_requested(:get, %r{/stream/series/})
  end
end
