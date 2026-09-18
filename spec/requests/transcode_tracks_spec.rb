require 'rails_helper'

RSpec.describe "Transcode source chapter metadata", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:source_url) { "https://download.real-debrid.com/d/chapters/episode.mp4" }
  let(:source) { signed_source_for(user, url: source_url, filename: "episode.mp4") }
  let(:probe_data) do
    {
      "streams" => [
        { "index" => 0, "codec_type" => "video", "codec_name" => "h264", "codec_tag_string" => "avc1", "width" => 1280, "height" => 720, "pix_fmt" => "yuv420p" },
        { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } },
        { "index" => 2, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" } }
      ],
      "format" => { "duration" => "1800.500000" },
      "chapters" => [
        { "start_time" => "1740.125000", "end_time" => "1800.500000", "tags" => { "title" => "End Credits" } }
      ]
    }
  end

  before do
    Media::Transcoder.instance_variable_set(:@probe_cache, {})
    sign_in user
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
    allow(ExternalSubtitleService).to receive(:search).and_return([])
    allow(Media::Transcoder).to receive(:capture_command) do
      Media::Transcoder::CommandCaptureResult.new(
        stdout: probe_data.to_json,
        stderr: "",
        status: instance_double(Process::Status, success?: true),
        timed_out: false
      )
    end
  end

  after do
    Media::Transcoder.instance_variable_set(:@probe_cache, {})
  end

  it "exposes normalized chapters and source duration without another probe" do
    get transcode_tracks_path, params: { source: source }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["chapters"]).to eq([
      { "title" => "End Credits", "start_time" => 1740.125, "end_time" => 1800.5 }
    ])
    expect(response.parsed_body["duration"]).to eq(1800.5)
    expect(response.parsed_body["audio"].first).to include("index" => 1, "language" => "ENG")
    expect(response.parsed_body["subtitles"].first).to include("index" => 2, "text_supported" => true)
    expect(response.parsed_body).to include("direct_playable" => true, "remux_direct_playable" => true)
    expect(response.parsed_body["direct_stream_url"]).to eq(direct_stream_path(source: source))
    expect(response.parsed_body["remux_direct_url"]).to eq(transcode_stream_path(source: source, remux: 1))

    get transcode_tracks_path, params: { source: source }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["chapters"].size).to eq(1)

    get transcode_duration_path, params: { source: source }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["duration"]).to eq(1800.5)
    expect(Media::Transcoder).to have_received(:capture_command).once
  end

  it "returns an empty chapter array without inventing an unavailable duration" do
    probe_data.delete("chapters")
    probe_data.delete("format")

    get transcode_tracks_path, params: { source: source }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["chapters"]).to eq([])
    expect(response.parsed_body).not_to have_key("duration")
    expect(response.parsed_body["audio"].first["index"]).to eq(1)
    expect(Media::Transcoder).to have_received(:capture_command).once
  end

  it "ignores malformed chapter metadata without changing playback compatibility" do
    probe_data["chapters"] = [
      nil,
      { "start_time" => "NaN", "end_time" => "1800.5" },
      { "start_time" => "1800", "end_time" => "Infinity" },
      { "start_time" => "1800", "end_time" => "1799" },
      { "start_time" => "1800", "end_time" => "1900" }
    ]

    get transcode_tracks_path, params: { source: source }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("chapters" => [], "duration" => 1800.5, "direct_playable" => true, "remux_direct_playable" => true)
    expect(Media::Transcoder).to have_received(:capture_command).once
  end

  it "returns empty chapters on a profile failure without retrying the probe" do
    allow(ExternalSubtitleService).to receive(:search).and_raise(StandardError, "subtitle service unavailable")

    get transcode_tracks_path, params: { source: source }

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body).to include("audio" => [], "subtitles" => [], "chapters" => [])
    expect(Media::Transcoder).to have_received(:capture_command).once
  end

  it "rejects invalid sources before probing and returns an empty chapter array" do
    get transcode_tracks_path, params: { source: "tampered" }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("audio" => [], "subtitles" => [], "chapters" => [])
    expect(Media::Transcoder).not_to have_received(:capture_command)
  end
end
