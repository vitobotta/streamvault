require "rails_helper"

RSpec.describe MediaProfileService do
  let(:headers) { { "Authorization" => "Bearer token" } }
  let(:subtitle_search) do
    {
      imdb_id: "tt1375666",
      type: "movie",
      season: nil,
      episode: nil,
      title: "Inception",
      filename: filename,
      preferred_languages: [ "ENG" ],
      default_language: "ENG"
    }
  end
  let(:filename) { "movie.mp4" }
  let(:audio_tracks) { [ { index: 1, codec: "aac", default: true } ] }
  let(:embedded_subtitles) { [] }
  let(:video_stream) do
    { codec_name: "h264", codec_tag: "avc1", width: 1920, height: 1080, pix_fmt: "yuv420p" }
  end
  let(:media_info) do
    {
      media_tracks: { audio: audio_tracks, subtitles: embedded_subtitles },
      video_stream: video_stream
    }
  end

  subject(:service) do
    described_class.new(
      input_url: "https://download.real-debrid.com/movie.mp4",
      filename: filename,
      headers: headers,
      subtitle_search: subtitle_search
    )
  end

  before do
    allow(Media::Transcoder).to receive(:probe_media_info).and_return(media_info)
    allow(ExternalSubtitleService).to receive(:search).and_return([])
    allow(Media::Transcoder).to receive(:selectable_subtitle_tracks) { |tracks| tracks }
  end

  it "identifies a safe H.264 MP4 with AAC as direct and remux playable" do
    result = service.call

    expect(result).to be_success
    expect(result.data.to_h).to include(
      video_codec: "h264",
      video_codec_tag: "avc1",
      direct_playable: true,
      remux_direct_playable: true
    )
  end

  it "requires an MP4-family container for native direct play" do
    result = described_class.new(
      input_url: "https://download.real-debrid.com/movie.mkv",
      filename: "movie.mkv",
      headers: headers,
      subtitle_search: subtitle_search.merge(filename: "movie.mkv")
    ).call

    expect(result.data[:direct_playable]).to be(false)
    expect(result.data[:remux_direct_playable]).to be(true)
  end

  it "rejects unsafe H.264 dimensions from native direct play" do
    video_stream[:width] = 3840
    video_stream[:height] = 2160

    result = service.call

    expect(result.data[:direct_playable]).to be(false)
    expect(result.data[:remux_direct_playable]).to be(true)
  end

  it "rejects a non-AAC default audio track from native direct play" do
    audio_tracks.first[:codec] = "eac3"

    expect(service.call.data[:direct_playable]).to be(false)
  end

  it "merges external and embedded subtitles before selecting tracks" do
    external = { index: "external:1", external: true, language: "eng" }
    embedded = { index: 2, language: "eng" }
    embedded_subtitles << embedded
    allow(ExternalSubtitleService).to receive(:search).and_return([ external ])

    result = service.call

    expect(result.data[:subtitles]).to eq([ embedded, external ])
    expect(Media::Transcoder).to have_received(:selectable_subtitle_tracks).with([ embedded, external ])
  end
end
