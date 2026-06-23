require 'rails_helper'

RSpec.describe "Transcode", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }

  before do
    sign_in user
  end

  describe "GET /transcode" do
    it "rejects non-HTTP media URLs before invoking ffmpeg" do
      expect(TranscodeService).not_to receive(:transcode_to_fmp4)

      get transcode_stream_path, params: { url: "file:///etc/passwd" }

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects localhost media URLs before invoking ffmpeg" do
      expect(TranscodeService).not_to receive(:transcode_to_fmp4)

      get transcode_stream_path, params: { url: "http://127.0.0.1:3000/internal.mp4" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /transcode/tracks" do
    it "returns probed media tracks" do
      tracks = {
        audio: [ { index: 1, language: "ENG", language_label: "English", label: "English", default: true } ],
        subtitles: [ { index: 2, language: "FRENCH", language_label: "French", label: "French", text_supported: true } ]
      }
      allow(TranscodeService).to receive(:probe_media_tracks).and_return(tracks)
      allow(ExternalSubtitleService).to receive(:search).and_return([])

      get transcode_tracks_path, params: { url: "https://download.real-debrid.com/d/file123/Inception.mkv" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["audio"].first["language"]).to eq("ENG")
      expect(response.parsed_body["subtitles"].first["language"]).to eq("FRENCH")
    end

    it "adds external subtitle tracks using content metadata" do
      tracks = { audio: [], subtitles: [] }
      external_subtitles = [
        {
          index: "external:subdl:abc",
          language: "ENG",
          language_label: "English",
          label: "English · SubDL · Release",
          text_supported: true,
          external: true,
          source: "subdl"
        }
      ]
      allow(TranscodeService).to receive(:probe_media_tracks).and_return(tracks)
      allow(ExternalSubtitleService).to receive(:search).and_return(external_subtitles)

      get transcode_tracks_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception",
        filename: "Inception.2010.1080p.mkv"
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["subtitles"].first["external"]).to eq(true)
      expect(ExternalSubtitleService).to have_received(:search).with(
        imdb_id: "tt1375666",
        type: "movie",
        season: nil,
        episode: nil,
        title: "Inception",
        filename: "Inception.2010.1080p.mkv",
        preferred_languages: user.preferred_stream_languages,
        default_language: user.default_stream_language
      )
    end

    it "rejects private media URLs" do
      expect(TranscodeService).not_to receive(:probe_media_tracks)
      expect(ExternalSubtitleService).not_to receive(:search)

      get transcode_tracks_path, params: { url: "http://localhost/video.mkv" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /transcode/subtitles" do
    it "rejects private subtitle media URLs before extracting" do
      expect(TranscodeService).not_to receive(:extract_subtitles)

      get transcode_subtitles_path, params: {
        url: "http://127.0.0.1/video.mkv",
        subtitle_stream: "2"
      }

      expect(response).to have_http_status(:bad_request)
    end

    it "returns selected subtitles as WebVTT" do
      allow(TranscodeService).to receive(:extract_subtitles).and_return(
        TranscodeService::SubtitleExtractionResult.new(
          status: :ok,
          vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n",
          cue_count: 1,
          source: :ffmpeg
        )
      )

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "2",
        start_seconds: "30",
        duration_seconds: "5"
      }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vtt")
      expect(response.body).to start_with("WEBVTT")
      expect(TranscodeService).to have_received(:extract_subtitles).with(
        "https://download.real-debrid.com/d/file123/Inception.mkv",
        headers: { "Authorization" => "Bearer test_key" },
        subtitle_stream: "2",
        start_seconds: 30.0,
        duration_seconds: 5
      )
    end

    it "returns external subtitles as WebVTT" do
      allow(ExternalSubtitleService).to receive(:extract_subtitles).and_return(
        TranscodeService::SubtitleExtractionResult.new(
          status: :ok,
          vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nExternal\n",
          cue_count: 1,
          source: :subdl
        )
      )
      expect(TranscodeService).not_to receive(:extract_subtitles)

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "external:subdl:abc",
        start_seconds: "30",
        duration_seconds: "60"
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("External")
      expect(ExternalSubtitleService).to have_received(:extract_subtitles).with(
        "external:subdl:abc",
        start_seconds: 30.0,
        duration_seconds: 60
      )
    end

    it "uses the default subtitle window when duration is omitted" do
      allow(TranscodeService).to receive(:extract_subtitles).and_return(
        TranscodeService::SubtitleExtractionResult.new(
          status: :ok,
          vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n",
          cue_count: 1,
          source: :ffprobe_packets
        )
      )

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "2",
        start_seconds: "30"
      }

      expect(response).to have_http_status(:ok)
      expect(TranscodeService).to have_received(:extract_subtitles).with(
        "https://download.real-debrid.com/d/file123/Inception.mkv",
        headers: { "Authorization" => "Bearer test_key" },
        subtitle_stream: "2",
        start_seconds: 30.0,
        duration_seconds: TranscodeService::SUBTITLE_EXTRACTION_WINDOW_SECONDS
      )
    end

    it "returns no content when the selected subtitle window has no cues" do
      allow(TranscodeService).to receive(:extract_subtitles).and_return(
        TranscodeService::SubtitleExtractionResult.new(status: :empty_window, vtt: "", cue_count: 0, source: :ffprobe_packets)
      )

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "2",
        start_seconds: "30"
      }

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
    end

    it "returns gateway timeout when subtitle extraction times out" do
      allow(TranscodeService).to receive(:extract_subtitles).and_return(
        TranscodeService::SubtitleExtractionResult.new(status: :timeout, vtt: "", cue_count: 0, source: :ffmpeg)
      )

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "2",
        start_seconds: "30"
      }

      expect(response).to have_http_status(:gateway_timeout)
      expect(response.parsed_body["error"]).to eq("Subtitle extraction timed out")
    end

    it "returns unprocessable entity for unsupported subtitle tracks" do
      allow(TranscodeService).to receive(:extract_subtitles).and_return(
        TranscodeService::SubtitleExtractionResult.new(status: :unsupported_track, vtt: "", cue_count: 0, source: nil)
      )

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "4",
        start_seconds: "30"
      }

      expect(response).to have_http_status(422)
      expect(response.parsed_body["error"]).to eq("Subtitle track is not available")
    end

    it "returns bad gateway when subtitle extraction fails" do
      allow(TranscodeService).to receive(:extract_subtitles).and_return(
        TranscodeService::SubtitleExtractionResult.new(status: :failed, vtt: "", cue_count: 0, source: :ffmpeg)
      )

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "2",
        start_seconds: "30"
      }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["error"]).to eq("Subtitle extraction failed")
    end
  end
end
