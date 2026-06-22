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

      get transcode_tracks_path, params: { url: "https://download.real-debrid.com/d/file123/Inception.mkv" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["audio"].first["language"]).to eq("ENG")
      expect(response.parsed_body["subtitles"].first["language"]).to eq("FRENCH")
    end

    it "rejects private media URLs" do
      expect(TranscodeService).not_to receive(:probe_media_tracks)

      get transcode_tracks_path, params: { url: "http://localhost/video.mkv" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /transcode/subtitles" do
    it "returns selected subtitles as WebVTT" do
      allow(TranscodeService).to receive(:extract_subtitles_to_vtt)
        .and_return("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n")

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "2",
        start_seconds: "30"
      }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vtt")
      expect(response.body).to start_with("WEBVTT")
      expect(TranscodeService).to have_received(:extract_subtitles_to_vtt).with(
        "https://download.real-debrid.com/d/file123/Inception.mkv",
        headers: { "Authorization" => "Bearer test_key" },
        subtitle_stream: "2",
        start_seconds: 30.0
      )
    end

    it "returns an empty WebVTT document when the selected window has no cues" do
      allow(TranscodeService).to receive(:extract_subtitles_to_vtt).and_return("")

      get transcode_subtitles_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        subtitle_stream: "2",
        start_seconds: "30"
      }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vtt")
      expect(response.body).to eq("WEBVTT\n\n")
    end
  end
end
