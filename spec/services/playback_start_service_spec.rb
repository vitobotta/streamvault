require "rails_helper"

RSpec.describe PlaybackStartService do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:streaming_service) { instance_double(ContentStreamingService) }
  subject(:service) { described_class.new(user, streaming_service: streaming_service) }

  it "builds the player payload for an automatically selected stream" do
    allow(streaming_service).to receive(:start_stream)
      .with("tt1375666", "movie", season: nil, episode: nil)
      .and_return(ServiceResult.success(streaming_url: "https://media.test/movie.mp4", filename: "movie.mp4"))
    allow_any_instance_of(TorrentioService).to receive(:metadata)
      .and_return(ServiceResult.success(runtime_seconds: 7_200))

    result = service.start(imdb_id: "tt1375666", type: "movie", title: "Inception")

    expect(result).to be_success
    expect(result.data).to include(
      streaming_url: "https://media.test/movie.mp4",
      filename: "movie.mp4",
      imdb_id: "tt1375666",
      type: "movie",
      title: "Inception",
      duration: 7_200
    )
  end

  it "resolves an explicit selection and preserves its direct-play hint" do
    allow(streaming_service).to receive(:resolve_single)
      .with(
        "https://provider.test/resolve/1",
        filename: "movie.mp4",
        imdb_id: "tt1375666",
        type: "movie",
        season: nil,
        episode: nil,
        duration: 7_200,
        raw_size: 1_000,
        video_codec: "h264",
        compatibility_score: 100
      )
      .and_return(ServiceResult.success(
        streaming_url: "https://media.test/movie.mp4",
        filename: "movie.mp4",
        direct_play_hint: true
      ))

    result = service.start(
      imdb_id: "tt1375666",
      type: "movie",
      requested_duration: 7_200,
      selection: {
        resolve_url: "https://provider.test/resolve/1",
        filename: "movie.mp4",
        duration: 7_200,
        raw_size: 1_000,
        video_codec: "h264",
        compatibility_score: 100
      }
    )

    expect(result.data).to include(duration: 7_200, direct_play_hint: true)
  end

  it "prefers a saved duration and position over a requested duration" do
    create(:watch_history_entry, :movie,
      user: user,
      imdb_id: "tt1375666",
      progress_seconds: 3_600,
      duration_seconds: 7_200)
    allow(streaming_service).to receive(:start_stream)
      .and_return(ServiceResult.success(streaming_url: "https://media.test/movie.mp4", filename: "movie.mp4"))

    result = service.start(imdb_id: "tt1375666", type: "movie", requested_duration: 8_880)

    expect(result.data).to include(resume_at: 3_600, duration: 7_200)
  end

  it "uses an already-resolved resume target without another progress lookup" do
    allow(streaming_service).to receive(:start_stream)
      .with("tt0903747", "show", season: 2, episode: 3)
      .and_return(ServiceResult.success(streaming_url: "https://media.test/episode.mp4", filename: "episode.mp4"))

    result = service.resume(
      imdb_id: "tt0903747",
      type: "show",
      target: {
        season: 2,
        episode: 3,
        resume_at: 90,
        title: "Breaking Bad",
        poster_url: nil,
        duration_seconds: 3_000
      }
    )

    expect(result.data).to include(season: 2, episode: 3, resume_at: 90, duration: 3_000)
  end

  it "propagates stream resolution failures" do
    failure = ServiceResult.failure("No playable streams")
    allow(streaming_service).to receive(:start_stream).and_return(failure)

    expect(service.start(imdb_id: "tt1375666", type: "movie")).to equal(failure)
  end
end
