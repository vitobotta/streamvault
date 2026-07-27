require 'rails_helper'

RSpec.describe Streams::Resolver do
  let(:user) { create(:user, realdebrid_api_key: "test_key_123") }
  let(:available_streams) { instance_double(AvailableStreamsService) }
  let(:content_ref) { ContentRef.new(imdb_id: "tt1375666", type: "movie") }
  subject(:resolver) { described_class.new(user, available_streams: available_streams) }

  around do |example|
    previous = ENV["STREAM_PROVIDER"]
    ENV["STREAM_PROVIDER"] = "torrentio"
    example.run
  ensure
    ENV["STREAM_PROVIDER"] = previous
  end

  it "fails before provider fan-out when the RealDebrid key is missing" do
    user.update!(realdebrid_api_key: nil)
    expect(available_streams).not_to receive(:call)

    result = resolver.start(content_ref)
    expect(result).to be_failure
    expect(result.error_message).to include("RealDebrid API key")
  end

  it "returns a clear failure when no candidates are available" do
    allow(available_streams).to receive(:call).and_return(ServiceResult.success([]))

    result = resolver.start(content_ref)

    expect(result).to be_failure
    expect(result.error_message).to include("No instant streams")
  end

  it "returns the resolved source and selected candidate" do
    candidate = StreamCandidate.new(
      title: "Inception 1080p",
      filename: "Inception.mkv",
      resolve_url: "https://torrentio.strem.fun/resolve/realdebrid/test_key/abc/null/0/Inception.mkv",
      compatibility_score: StreamCompatibility::COMPATIBILITY_SCORES[:stream_copy]
    )
    allow(available_streams).to receive(:call).and_return(ServiceResult.success([ candidate ]))
    stub_request(:get, candidate.resolve_url)
      .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file/Inception.mkv" })

    result = resolver.start(content_ref)

    expect(result).to be_success
    expect(result.data[:source].url).to eq("https://download.real-debrid.com/d/file/Inception.mkv")
    expect(result.data[:stream].filename).to eq("Inception.mkv")
  end

  it "skips blocked placeholders and resolves the next candidate" do
    blocked = StreamCandidate.new(
      title: "Blocked",
      resolve_url: "https://torrentio.strem.fun/resolve/realdebrid/test_key/blocked/null/0/blocked.mkv"
    )
    working = StreamCandidate.new(
      title: "Working",
      resolve_url: "https://torrentio.strem.fun/resolve/realdebrid/test_key/working/null/0/working.mp4"
    )
    allow(available_streams).to receive(:call).and_return(ServiceResult.success([ blocked, working ]))
    stub_request(:get, blocked.resolve_url)
      .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/failed_unexpected.mp4" })
    stub_request(:get, working.resolve_url)
      .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file/working.mp4" })

    result = resolver.start(content_ref)

    expect(result).to be_success
    expect(result.data[:source].url).to end_with("/working.mp4")
  end

  it "accepts a configured HTTP Comet intermediary with a RealDebrid destination" do
    ENV["STREAM_PROVIDER"] = "auto"
    ENV["COMET_URL"] = "http://comet.test:8000"
    candidate = StreamCandidate.new(
      title: "Comet stream",
      resolve_url: "http://comet.test:8000/playback/working",
      provider: "CometService"
    )
    allow(available_streams).to receive(:call).and_return(ServiceResult.success([ candidate ]))
    stub_request(:get, candidate.resolve_url)
      .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file/working.mp4" })

    result = resolver.start(content_ref)

    expect(result).to be_success
    expect(result.data[:source].url).to end_with("/working.mp4")
  end

  it "does not let one provider consume every resolution attempt" do
    ENV["STREAM_PROVIDER"] = "auto"
    ENV["COMET_URL"] = "http://comet.test:8000"
    comet_candidates = 50.times.map do |index|
      StreamCandidate.new(
        title: "Blocked Comet stream #{index}",
        resolve_url: "http://comet.test:8000/playback/blocked-#{index}",
        provider: "CometService"
      )
    end
    torrentio_candidate = StreamCandidate.new(
      title: "Working Torrentio stream",
      resolve_url: "https://torrentio.strem.fun/resolve/realdebrid/test_key/working/null/0/working.mp4",
      provider: "Streams::TorrentioProvider"
    )
    allow(available_streams).to receive(:call)
      .and_return(ServiceResult.success(comet_candidates + [ torrentio_candidate ]))
    stub_request(:get, %r{comet\.test:8000/playback/blocked-})
      .to_return(status: 302, headers: { "Location" => "https://torrentio.strem.fun/videos/failed_unexpected.mp4" })
    stub_request(:get, torrentio_candidate.resolve_url)
      .to_return(status: 302, headers: { "Location" => "https://download.real-debrid.com/d/file/working.mp4" })

    result = resolver.start(content_ref)

    expect(result).to be_success
    expect(result.data[:stream].provider).to eq("Streams::TorrentioProvider")
  end

  it "rejects configured providers that redirect outside RealDebrid" do
    ENV["STREAM_PROVIDER"] = "auto"
    ENV["COMET_URL"] = "http://comet.test:8000"
    candidate = StreamCandidate.new(
      title: "Compromised stream",
      resolve_url: "http://comet.test:8000/playback/untrusted",
      provider: "CometService"
    )
    allow(available_streams).to receive(:call).and_return(ServiceResult.success([ candidate ]))
    stub_request(:get, candidate.resolve_url)
      .to_return(status: 302, headers: { "Location" => "https://evil.example/video.mp4" })

    expect(resolver.start(content_ref)).to be_failure
  end

  it "never requests resolve URLs outside configured provider origins" do
    candidate = StreamCandidate.new(title: "Untrusted", resolve_url: "https://evil.example/resolve")
    allow(available_streams).to receive(:call).and_return(ServiceResult.success([ candidate ]))

    expect(resolver.start(content_ref)).to be_failure
    expect(WebMock).not_to have_requested(:get, candidate.resolve_url)
  end
end
