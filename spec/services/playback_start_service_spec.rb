require "rails_helper"

RSpec.describe PlaybackStartService do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:resolver) { instance_double(Streams::Resolver) }
  let(:catalog) { instance_double(Catalog::CinemetaClient) }
  let(:source) do
    ResolvedSource.new(
      url: "https://download.real-debrid.com/d/file/movie.mp4",
      filename: "movie.mp4"
    )
  end
  let(:stream_result) do
    ServiceResult.success(source: source, stream: StreamCandidate.new(filename: source.filename))
  end

  subject(:service) do
    described_class.new(user, streaming_service: resolver, catalog: catalog)
  end

  before do
    allow(catalog).to receive(:metadata).and_return(ServiceResult.failure("metadata unavailable"))
  end

  it "builds a playback descriptor for an automatically selected stream" do
    content_ref = ContentRef.new(imdb_id: "tt1375666", type: "movie")
    allow(resolver).to receive(:start).with(content_ref).and_return(stream_result)
    allow(catalog).to receive(:metadata)
      .with("tt1375666", "movie")
      .and_return(ServiceResult.success(runtime_seconds: 7_200))

    result = service.start(imdb_id: "tt1375666", type: "movie", title: "Inception")

    expect(result).to be_success
    expect(result.data).to be_a(PlaybackDescriptor)
    expect(result.data.to_h).to include(
      filename: "movie.mp4",
      content_ref: content_ref.to_h,
      title: "Inception",
      duration: 7_200
    )
    resolved_source = ResolvedSource.resolve(token: result.data.source_token, user: user, verify_dns: false)
    expect(resolved_source.to_h).to eq(source.to_h)
  end

  it "resolves an explicit selection and preserves its direct-play hint" do
    allow(resolver).to receive(:resolve) do |candidate, content_ref:, duration:|
      expect(candidate).to eq(StreamCandidate.new(
        resolve_url: "https://provider.test/resolve/1",
        filename: "movie.mp4",
        raw_size: 1_000,
        video_codec: "h264",
        compatibility_score: 100
      ))
      expect(content_ref).to eq(ContentRef.new(imdb_id: "tt1375666", type: "movie"))
      expect(duration).to eq(7_200)
      ServiceResult.success(source: source, stream: candidate, direct_play_hint: true)
    end

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

    expect(result.data.to_h).to include(duration: 7_200, direct_play_hint: true)
  end

  it "prefers a saved duration and position over a requested duration" do
    create(:playback_progress, :movie,
      user: user,
      imdb_id: "tt1375666",
      progress_seconds: 3_600,
      duration_seconds: 7_200)
    allow(resolver).to receive(:start).and_return(stream_result)

    result = service.start(imdb_id: "tt1375666", type: "movie", requested_duration: 8_880)

    expect(result.data.to_h).to include(resume_at: 3_600.0, duration: 7_200)
  end

  it "uses an already-resolved resume target" do
    content_ref = ContentRef.new(imdb_id: "tt0903747", type: "show", season: 2, episode: 3)
    allow(resolver).to receive(:start).with(content_ref).and_return(stream_result)

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

    expect(result.data.to_h).to include(
      content_ref: content_ref.to_h,
      resume_at: 90.0,
      duration: 3_000
    )
  end

  it "uses an episode-free resume target for a movie" do
    content_ref = ContentRef.new(imdb_id: "tt1375666", type: "movie")
    allow(resolver).to receive(:start).with(content_ref).and_return(stream_result)

    result = service.resume(
      imdb_id: "tt1375666",
      type: "movie",
      target: {
        season: nil,
        episode: nil,
        resume_at: 3_000,
        title: "Inception",
        poster_url: "https://example.com/inception.jpg",
        duration_seconds: 7_200
      }
    )

    expect(result).to be_success
    expect(result.data.to_h).to include(
      content_ref: content_ref.to_h,
      resume_at: 3_000.0,
      duration: 7_200
    )
  end

  it "propagates stream resolution failures" do
    failure = ServiceResult.failure("No playable streams")
    allow(resolver).to receive(:start).and_return(failure)

    expect(service.start(imdb_id: "tt1375666", type: "movie")).to equal(failure)
  end
end
