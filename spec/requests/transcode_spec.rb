require 'rails_helper'

RSpec.describe "Transcode", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }

  before do
    sign_in user
    # Stub DNS so download.real-debrid.com (which doesn't resolve in
    # offline test envs) passes the SSRF guard's public-address check.
    # RealDebrid's CDN host is allowlisted in StreamUrlValidation.
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
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

    it "rejects non-allowlisted public media URLs before invoking ffmpeg" do
      expect(TranscodeService).not_to receive(:transcode_to_fmp4)

      get transcode_stream_path, params: { url: "https://example.com/video.mkv" }

      expect(response).to have_http_status(:bad_request)
    end

    it "returns bad gateway when ffmpeg fails before producing data" do
      allow(TranscodeService).to receive(:transcode_to_fmp4).and_raise(
        TranscodeService::TranscodeError, "FFmpeg exited without producing output. stderr: error"
      )

      get transcode_stream_path, params: { url: "https://download.real-debrid.com/d/file123/video.mkv" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.content_type).to include("text/plain")
      expect(response.body).to include("Unable to start stream")
    end

    it "logs and closes gracefully when ffmpeg stalls after data is committed" do
      allow(TranscodeService).to receive(:transcode_to_fmp4) do |*_args, &block|
        block.call("fMP4 data chunk")
        raise TranscodeService::TranscodeError, "FFmpeg stream stalled — no data for 20s."
      end
      allow(Rails.logger).to receive(:error)

      get transcode_stream_path, params: { url: "https://download.real-debrid.com/d/file123/video.mkv" }

      expect(Rails.logger).to have_received(:error).with(/\[Transcode\].*stream stalled/)
      expect(response).to have_http_status(:ok)
    end

    it "clamps start_seconds to 24 hours (MAX_START_SECONDS)" do
      captured_kwargs = nil
      allow(TranscodeService).to receive(:transcode_to_fmp4) do |*_args, **kwargs|
        captured_kwargs = kwargs
        raise TranscodeService::TranscodeError, "stub"
      end

      get transcode_stream_path, params: {
        url: "https://download.real-debrid.com/d/file123/video.mkv",
        start_seconds: "999999"
      }

      expect(captured_kwargs[:start_seconds]).to eq(86_400) # 24*60*60
    end

    it "clamps negative start_seconds to 0" do
      captured_kwargs = nil
      allow(TranscodeService).to receive(:transcode_to_fmp4) do |*_args, **kwargs|
        captured_kwargs = kwargs
        raise TranscodeService::TranscodeError, "stub"
      end

      get transcode_stream_path, params: {
        url: "https://download.real-debrid.com/d/file123/video.mkv",
        start_seconds: "-100"
      }

      expect(captured_kwargs[:start_seconds]).to eq(0)
    end
  end

  describe "GET /transcode/tracks" do
    it "loads media metadata and external subtitles concurrently" do
      mutex = Mutex.new
      condition = ConditionVariable.new
      started = 0
      barrier = lambda do |result|
        mutex.synchronize do
          started += 1
          condition.broadcast
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
          while started < 2
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise "metadata operations ran serially" unless remaining.positive?

            condition.wait(mutex, remaining)
          end
        end
        result
      end
      allow(TranscodeService).to receive(:probe_media_info) do
        barrier.call(media_tracks: { audio: [], subtitles: [] }, video_stream: {})
      end
      allow(ExternalSubtitleService).to receive(:search) { barrier.call([]) }

      get transcode_tracks_path, params: { url: "https://download.real-debrid.com/d/file123/Inception.mkv" }

      expect(response).to have_http_status(:ok)
      expect(started).to eq(2)
    end

    it "returns probed media tracks" do
      tracks = {
        audio: [ { index: 1, language: "ENG", language_label: "English", label: "English", default: true } ],
        subtitles: [
          { index: 2, language: "FRENCH", language_label: "French", label: "French", text_supported: true, partial: false, quality_score: 0 },
          { index: 3, language: "FRENCH", language_label: "French", label: "French · Forced", text_supported: true, partial: true, quality_score: 100 }
        ]
      }
      allow(TranscodeService).to receive(:probe_media_info).and_return(media_tracks: tracks, video_stream: {})
      allow(ExternalSubtitleService).to receive(:search).and_return([])

      get transcode_tracks_path, params: { url: "https://download.real-debrid.com/d/file123/Inception.mkv" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["audio"].first["language"]).to eq("ENG")
      expect(response.parsed_body["subtitles"].pluck("index")).to eq([ 2 ])
    end

    it "offers HEVC MP4 with default AAC audio as a native direct-play candidate" do
      tracks = {
        audio: [ { index: 1, codec: "aac", default: true, language: "ENG" } ],
        subtitles: []
      }
      video = { codec_name: "hevc", codec_tag: "hev1", width: 1920, height: 816, pix_fmt: "yuv420p10le" }
      allow(TranscodeService).to receive(:probe_media_info).and_return(media_tracks: tracks, video_stream: video)
      allow(ExternalSubtitleService).to receive(:search).and_return([])

      get transcode_tracks_path, params: {
        url: "https://download.real-debrid.com/d/file123/movie.mp4",
        filename: "movie.mp4"
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["direct_playable"]).to eq(true)
      expect(response.parsed_body["remux_direct_playable"]).to eq(true)
      expect(response.parsed_body["video_codec_tag"]).to eq("hev1")
    end

    it "keeps HEVC MKV on the remux path" do
      tracks = {
        audio: [ { index: 1, codec: "aac", default: true, language: "ENG" } ],
        subtitles: []
      }
      video = { codec_name: "hevc", width: 1920, height: 816, pix_fmt: "yuv420p10le" }
      allow(TranscodeService).to receive(:probe_media_info).and_return(media_tracks: tracks, video_stream: video)
      allow(ExternalSubtitleService).to receive(:search).and_return([])

      get transcode_tracks_path, params: {
        url: "https://download.real-debrid.com/d/file123/movie.mkv",
        filename: "movie.mkv"
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["direct_playable"]).to eq(false)
      expect(response.parsed_body["remux_direct_playable"]).to eq(true)
    end

    it "does not direct-play when the default audio track is not AAC" do
      tracks = {
        audio: [
          { index: 1, codec: "ac3", default: true, language: "ENG" },
          { index: 2, codec: "aac", default: false, language: "FRENCH" }
        ],
        subtitles: []
      }
      video = { codec_name: "hevc", width: 1920, height: 816, pix_fmt: "yuv420p10le" }
      allow(TranscodeService).to receive(:probe_media_info).and_return(media_tracks: tracks, video_stream: video)
      allow(ExternalSubtitleService).to receive(:search).and_return([])

      get transcode_tracks_path, params: {
        url: "https://download.real-debrid.com/d/file123/movie.mp4",
        filename: "movie.mp4"
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["direct_playable"]).to eq(false)
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
      allow(TranscodeService).to receive(:probe_media_info).and_return(media_tracks: tracks, video_stream: {})
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
      expect(TranscodeService).not_to receive(:probe_media_info)
      expect(ExternalSubtitleService).not_to receive(:search)

      get transcode_tracks_path, params: { url: "http://localhost/video.mkv" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /transcode/seek" do
    it "returns a keyframe-aligned copy plan" do
      allow(TranscodeService).to receive(:probe_remux_seek)
        .and_return(anchor_seconds: 120.0, input_seek_seconds: 123.5, skip_seconds: 3.5)

      get transcode_seek_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        start_seconds: 123.5
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "copy_safe" => true,
        "anchor_seconds" => 120.0,
        "input_seek_seconds" => 123.5,
        "skip_seconds" => 3.5
      )
    end

    it "fails closed when no trustworthy keyframe can be probed" do
      allow(TranscodeService).to receive(:probe_remux_seek).and_return(nil)

      get transcode_seek_path, params: {
        url: "https://download.real-debrid.com/d/file123/Inception.mkv",
        start_seconds: 123.5
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("copy_safe" => false)
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
