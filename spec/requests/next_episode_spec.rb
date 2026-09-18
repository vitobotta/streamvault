require "rails_helper"

RSpec.describe "Next episode playback", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:episodes) do
    [ { season: 1, episode: 1 }, { season: 1, episode: 2 }, { season: 2, episode: 1 } ]
  end
  let(:catalog) { instance_double(Catalog::CinemetaClient) }
  let(:playback) do
    signed_playback_for(user, imdb_id: "tt0903747", type: "show", season: 1, episode: 1,
      title: "Breaking Bad", poster_url: "https://img.example.com/show.jpg", duration: 2400)
  end

  before do
    sign_in user
    allow(Catalog::CinemetaClient).to receive(:new).and_return(catalog)
    allow(catalog).to receive(:metadata).with("tt0903747", "show")
      .and_return(ServiceResult.success(episodes: episodes))
  end

  def lookup(token = playback)
    get next_episode_streaming_path("play", playback: token)
  end

  it "loads availability in the background without resolving a stream or changing progress" do
    expect(PlaybackStartService).not_to receive(:new)
    expect { lookup }.not_to change(PlaybackProgress, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("available" => true, "season" => 1, "episode" => 2)
    expect(response.parsed_body.fetch("url")).to eq(resume_streaming_index_path(after: playback, autoplay: "1"))
    expect(response.body).not_to include("download.real-debrid.com")
  end

  it "crosses a season boundary" do
    lookup signed_playback_for(user, imdb_id: "tt0903747", type: "show", season: 1, episode: 2)
    expect(response.parsed_body).to include("available" => true, "season" => 2, "episode" => 1)
  end

  it "does not offer a next episode at the series finale" do
    lookup signed_playback_for(user, imdb_id: "tt0903747", type: "show", season: 2, episode: 1)
    expect(response.parsed_body).to eq("available" => false)
  end

  it "ignores specials when choosing the next episode" do
    episodes.unshift(season: 0, episode: 1)
    lookup
    expect(response.parsed_body).to include("season" => 1, "episode" => 2)
  end

  it "does not offer an episode known to be unreleased" do
    episodes[1][:released] = Date.tomorrow.iso8601
    lookup
    expect(response.parsed_body).to eq("available" => false)
  end

  it "allows an episode released today" do
    episodes[1][:released] = Date.current.iso8601
    lookup
    expect(response.parsed_body).to include("available" => true)
  end

  it "never looks up episodes for movies" do
    expect(catalog).not_to receive(:metadata)
    lookup signed_playback_for(user)
    expect(response.parsed_body).to eq("available" => false)
  end

  it "fails closed on a catalog outage without interrupting the player" do
    allow(catalog).to receive(:metadata).and_return(ServiceResult.failure("Unavailable"))
    lookup
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("available" => false)
  end

  it "requires authentication" do
    token = playback
    sign_out user
    lookup token
    expect(response).to redirect_to(new_user_session_path)
  end

  it "rejects invalid and other-user playback tokens" do
    lookup "tampered"
    expect(response).to have_http_status(:bad_request)
    lookup signed_playback_for(create(:user), imdb_id: "tt0903747", type: "show", season: 1, episode: 1)
    expect(response).to have_http_status(:bad_request)
  end

  it "renders a hidden TV-only prompt without a catalog round trip" do
    expect(catalog).not_to receive(:metadata)
    get streaming_path("play", playback: playback)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-video-player-target="nextEpisodePrompt"')
    expect(response.body).to include("Skip to the next episode")
    expect(response.body).to include('data-video-player-next-episode-prompt-seconds-value="90"')
    expect(response.body).to include('data-action="click->video-player#skipToNextEpisode"')
    get streaming_path("play", playback: signed_playback_for(user))
    expect(response.body).not_to include('data-video-player-target="nextEpisodePrompt"')
  end

  it "supports configurable timing, disabling the fallback, and invalid-value defaults" do
    original = ENV["NEXT_EPISODE_PROMPT_SECONDS"]
    { "120" => 120, "0" => 0, "invalid" => 90, "-1" => 0, "9999" => 600 }.each do |value, expected|
      ENV["NEXT_EPISODE_PROMPT_SECONDS"] = value
      get streaming_path("play", playback: playback)
      expect(response.body).to include(%(data-video-player-next-episode-prompt-seconds-value="#{expected}"))
    end
  ensure
    ENV["NEXT_EPISODE_PROMPT_SECONDS"] = original
  end

  it "persists completion and starts the current screen's next episode, not another tab's history" do
    patch progress_streaming_path("play"), params: {
      imdb_id: "tt0903747", type: "show", season: 1, episode: 1,
      title: "Breaking Bad", poster_url: "https://img.example.com/show.jpg",
      progress_seconds: 2400, duration_seconds: 2400
    }
    expect(response).to have_http_status(:ok)
    finished = user.playback_progresses.find_by!(season_number: 1, episode_number: 1)
    expect(PlaybackCompletionPolicy.episode_finished?(finished)).to be true
    create(:playback_progress, :episode, user: user, imdb_id: "tt0903747",
      season_number: 2, episode_number: 1, progress_seconds: 100, duration_seconds: 2400)

    next_token = signed_playback_for(user, imdb_id: "tt0903747", type: "show", season: 1, episode: 2)
    next_descriptor = PlaybackDescriptor.resolve(token: next_token, user: user)
    starter = instance_double(PlaybackStartService)
    allow(PlaybackStartService).to receive(:new).with(user).and_return(starter)
    expect(starter).to receive(:resume).with(
      imdb_id: "tt0903747", type: "show",
      target: { season: 1, episode: 2, resume_at: 0, duration_seconds: 0,
                title: "Breaking Bad", poster_url: "https://img.example.com/show.jpg" }
    ).and_return(ServiceResult.success(next_descriptor))

    lookup
    get response.parsed_body.fetch("url")
    expect(response).to have_http_status(:found)
    expect(redirected_playback_descriptor(response, user: user).content_ref.episode).to eq(2)
  end

  it "does not restart the finale or an unreleased next episode on explicit advance" do
    get resume_streaming_index_path(after: signed_playback_for(user, imdb_id: "tt0903747", type: "show", season: 2, episode: 1))
    expect(response).to have_http_status(:no_content)
    episodes[1][:released] = Date.tomorrow.iso8601
    get resume_streaming_index_path(after: playback)
    expect(response).to have_http_status(:no_content)
  end

  it "rejects invalid, foreign, and movie descriptors on explicit advance" do
    get resume_streaming_index_path(after: "tampered")
    expect(response).to redirect_to(root_path)
    get resume_streaming_index_path(after: signed_playback_for(create(:user)))
    expect(response).to redirect_to(root_path)
    get resume_streaming_index_path(after: signed_playback_for(user))
    expect(response).to have_http_status(:bad_request)
  end
end
