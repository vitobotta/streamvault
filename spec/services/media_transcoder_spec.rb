require 'rails_helper'

RSpec.describe Media::Transcoder do
  before do
    described_class.instance_variable_set(:@probe_cache, {})
    # Tests run against the software fallback (libx264) so the specs
    # don't depend on VideoToolbox being available on the CI machine.
    described_class.instance_variable_set(:@videotoolbox_available, false)
  end

  describe ".probe_duration" do
    it "uses the longest valid duration from ffprobe output" do
      output = {
        "format" => {
          "duration" => "0.100000",
          "tags" => { "DURATION" => "02:28:00.000000000" }
        },
        "streams" => [
          { "duration" => "8870.0" },
          { "tags" => { "DURATION" => "02:28:05.500000000" } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      duration = described_class.probe_duration("https://example.test/video-valid-duration.mkv")

      expect(duration).to eq(8885.5)
    end

    it "rejects tiny fragment durations" do
      output = {
        "format" => { "duration" => "0.100000" },
        "streams" => [ { "duration" => "0.200000" } ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      duration = described_class.probe_duration("https://example.test/video-fragment-duration.mkv")

      expect(duration).to eq(0)
    end
  end

  describe ".probe_media_tracks" do
    it "returns canonical audio and subtitle track metadata" do
      output = {
        "streams" => [
          { "index" => 0, "codec_type" => "video", "codec_name" => "h264" },
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "channels" => 6, "tags" => { "language" => "eng", "title" => "Main" }, "disposition" => { "default" => 1 } },
          { "index" => 2, "codec_type" => "audio", "codec_name" => "ac3", "channels" => 2, "tags" => { "language" => "fre" }, "disposition" => { "default" => 0 } },
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "spa", "title" => "Full" }, "disposition" => { "default" => 0 } },
          { "index" => 4, "codec_type" => "subtitle", "codec_name" => "hdmv_pgs_subtitle", "tags" => { "language" => "ger" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      tracks = described_class.probe_media_tracks("https://example.test/video-tracks.mkv")

      expect(tracks[:audio].map { |track| track.slice(:index, :language, :language_label, :channels, :default) }).to eq([
        { index: 1, language: "ENG", language_label: "English", channels: 6, default: true },
        { index: 2, language: "FRENCH", language_label: "French", channels: 2, default: false }
      ])
      expect(tracks[:subtitles].map { |track| track.slice(:index, :language, :text_supported) }).to eq([
        { index: 3, language: "SPANISH", text_supported: true },
        { index: 4, language: "GERMAN", text_supported: false }
      ])
      expect(tracks[:subtitles].first).to include(quality: "full", partial: false, quality_score: 0)
    end

    it "marks forced subtitle tracks as partial" do
      output = {
        "streams" => [
          {
            "index" => 3,
            "codec_type" => "subtitle",
            "codec_name" => "subrip",
            "tags" => { "language" => "eng", "title" => "Signs & Songs" },
            "disposition" => { "default" => 0, "forced" => 1 }
          }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      tracks = described_class.probe_media_tracks("https://example.test/video-tracks.mkv")

      expect(tracks[:subtitles].first).to include(
        forced: true,
        partial: true,
        quality: "partial"
      )
      expect(tracks[:subtitles].first[:label]).to include("Signs & Songs")
    end

    it "filters partial subtitles when a full dialogue alternative exists" do
      full_track = { index: 2, language: "ENG", label: "English", partial: false, quality_score: 0 }
      forced_track = { index: 3, language: "ENG", label: "English · Forced", partial: true, quality_score: 100 }
      french_forced_track = { index: 4, language: "FRENCH", label: "French · Forced", partial: true, quality_score: 100 }

      tracks = described_class.selectable_subtitle_tracks([ forced_track, full_track, french_forced_track ])

      expect(tracks).to eq([ full_track, french_forced_track ])
    end
  end

  describe ".probe_media_info" do
    it "loads track and video compatibility metadata with one remote probe" do
      output = {
        "streams" => [
          { "index" => 0, "codec_type" => "video", "codec_name" => "h264", "codec_tag_string" => "avc1", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p", "has_b_frames" => 2 },
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "channels" => 6, "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } }
        ]
      }.to_json
      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      info = described_class.probe_media_info("https://example.test/fast-start.mp4")

      expect(info[:media_tracks][:audio].first).to include(codec: "aac", language: "ENG", default: true)
      expect(info[:video_stream]).to include(codec_name: "h264", codec_tag: "avc1", width: 1920, height: 1080)
      expect(described_class.probe_media_tracks("https://example.test/fast-start.mp4")).to eq(info[:media_tracks])
      expect(described_class.probe_video_stream("https://example.test/fast-start.mp4")).to eq(info[:video_stream])
      expect(described_class).to have_received(:capture_command).once
    end
  end

  describe ".probe_remux_seek" do
    it "keeps the keyframe timeline while seeking FFmpeg to the exact target" do
      output = { "frames" => [ { "best_effort_timestamp_time" => "10.0" } ] }.to_json
      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      plan = described_class.probe_remux_seek(
        "https://example.test/video.mkv",
        target_seconds: 15
      )

      expect(plan).to eq(anchor_seconds: 10.0, input_seek_seconds: 15.0, skip_seconds: 5.0)
    end

    it "uses a zero input seek without probing at the beginning" do
      expect(described_class).not_to receive(:capture_command)

      plan = described_class.probe_remux_seek(
        "https://example.test/video.mkv",
        target_seconds: 0
      )

      expect(plan).to eq(anchor_seconds: 0.0, input_seek_seconds: 0.0, skip_seconds: 0.0)
    end

    it "fails closed when the preceding keyframe is too far behind" do
      output = { "frames" => [ { "best_effort_timestamp_time" => "0.0" } ] }.to_json
      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      plan = described_class.probe_remux_seek(
        "https://example.test/video.mkv",
        target_seconds: 180
      )

      expect(plan).to be_nil
    end
  end

  describe ".cache_store" do
    it "evicts oldest entries when cache exceeds the size limit" do
      described_class.instance_variable_set(:@probe_cache, {})
      (described_class::PROBE_CACHE_MAX_SIZE + 5).times do |i|
        described_class.send(:cache_store, "https://example.test/video#{i}.mkv", duration: 100)
      end
      expect(described_class.instance_variable_get(:@probe_cache).size).to eq(described_class::PROBE_CACHE_MAX_SIZE)
    end
  end

  describe "ffmpeg command selection" do
    it "encodes MSE output with the declared High Profile Level 4.0 contract" do
      output = {
        "streams" => [
          { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-h264-1080p.mkv",
        headers: { "Authorization" => "Bearer token" },
        start_seconds: 0
      )

      expect(argument_pairs(command)).to include(
        [ "-c:v", "libx264" ],
        [ "-profile:v", "high" ],
        [ "-level:v", "4.0" ]
      )
      expect(argument_pairs(command)).not_to include([ "-c:v", "copy" ])
      expect(command).not_to include("-ss")
      expect(argument_pairs(command)).to include([ "-headers", "Authorization: Bearer token\r\n" ])
      expect(argument_pairs(command)).to include(
        [ "-reconnect_at_eof", "1" ],
        [ "-reconnect_on_network_error", "1" ],
        [ "-reconnect_on_http_error", "429,5xx" ],
        [ "-reconnect_max_retries", "10" ],
        [ "-reconnect_delay_total_max", "30" ]
      )
    end

    it "transcodes standard MSE seeks but preserves copy for keyframe-aligned remux seeks" do
      output = {
        "streams" => [
          { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" }
        ]
      }.to_json
      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      standard = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-h264-1080p.mkv",
        headers: {},
        start_seconds: 42.5,
        remux: false
      )
      remux = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-h264-1080p.mkv",
        headers: {},
        start_seconds: 42.5,
        remux: true
      )
      expect(argument_pairs(standard)).to include(
        [ "-readrate", "1.25" ],
        [ "-readrate_initial_burst", "30" ]
      )
      expect(argument_pairs(remux)).to include(
        [ "-readrate", "1.05" ],
        [ "-readrate_initial_burst", "5" ]
      )

      expect(argument_pairs(standard)).to include([ "-c:v", "libx264" ])
      expect(argument_pairs(standard)).not_to include([ "-c:v", "copy" ])
      expect(argument_pairs(remux)).to include([ "-c:v", "copy" ])
      expect(remux).to include("-noaccurate_seek")
      expect(argument_pairs(remux)).to include([ "-ss", "42.5" ])
      expect(argument_pairs(remux)).not_to include([ "-tag:v", "hvc1" ])
    end

    it "marks copied HEVC as hvc1 for Safari-compatible fragmented MP4" do
      output = {
        "streams" => [
          { "codec_name" => "hevc", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p10le" }
        ]
      }.to_json
      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-hevc.mkv",
        headers: {},
        start_seconds: 42.5,
        remux: true
      )

      expect(argument_pairs(command)).to include(
        [ "-c:v", "copy" ],
        [ "-tag:v", "hvc1" ]
      )
    end

    it "transcodes HEVC/UHD video to browser-safe H.264" do
      output = {
        "streams" => [
          { "codec_name" => "hevc", "width" => 3840, "height" => 2160, "pix_fmt" => "yuv420p10le" }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-hevc-4k.mkv",
        headers: {},
        start_seconds: 0
      )

      expect(argument_pairs(command)).to include([ "-c:v", "libx264" ])
      expect(argument_pairs(command)).to include([ "-pix_fmt", "yuv420p" ])
      expect(command).to include("-vf")
      expect(command[command.index("-vf") + 1]).to include("min(1920,iw)")
      expect(command[command.index("-vf") + 1]).to include("min(1080,ih)")
      expect(argument_pairs(command)).not_to include([ "-c:v", "copy" ])
      expect(argument_pairs(command)).to include([ "-force_key_frames", "expr:gte(t,n_forced*2)" ])
    end

    it "transcodes when video probing fails closed" do
      allow(described_class).to receive(:capture_command).and_return(capture_result("", success: false))

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-unknown.mkv",
        headers: {},
        start_seconds: 0
      )

      expect(argument_pairs(command)).to include([ "-c:v", "libx264" ])
      expect(argument_pairs(command)).not_to include([ "-c:v", "copy" ])
    end

    it "maps the default language audio stream before other preferred audio streams" do
      video_output = {
        "streams" => [
          { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" }
        ]
      }.to_json
      track_output = {
        "streams" => [
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } },
          { "index" => 2, "codec_type" => "audio", "codec_name" => "aac", "tags" => { "language" => "fre" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-select_streams")
          capture_result(video_output)
        else
          capture_result(track_output)
        end
      end

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-french-audio.mkv",
        headers: {},
        start_seconds: 0,
        default_language: "FRENCH",
        preferred_languages: %w[ENG FRENCH]
      )

      expect(argument_pairs(command)).to include([ "-map", "0:2" ])
      expect(argument_pairs(command)).not_to include([ "-map", "0:a:0?" ])
    end

    it "burns the selected subtitle stream into the transcoded video" do
      video_output = {
        "streams" => [
          { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" }
        ]
      }.to_json
      track_output = {
        "streams" => [
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } },
          { "index" => 4, "codec_type" => "subtitle", "codec_name" => "hdmv_pgs_subtitle", "tags" => { "language" => "fre" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-select_streams")
          capture_result(video_output)
        else
          capture_result(track_output)
        end
      end

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-french-subtitles.mkv",
        headers: {},
        start_seconds: 120,
        subtitle_stream: "4"
      )

      subtitle_filter = "[0:v:0][0:s:0]overlay," \
        "scale=w='min(1920,iw)':h='min(1080,ih)':" \
        "force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p[v]"

      expect(argument_pairs(command)).to include([ "-filter_complex", subtitle_filter ])
      expect(argument_pairs(command)).to include([ "-map", "[v]" ])
      expect(argument_pairs(command)).not_to include([ "-map", "0:v:0" ])
      expect(argument_pairs(command)).to include([ "-c:v", "libx264" ])
      expect(argument_pairs(command)).not_to include([ "-c:v", "copy" ])
    end

    it "does not use the bitmap overlay filter for text subtitle streams" do
      video_output = {
        "streams" => [
          { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" }
        ]
      }.to_json
      track_output = {
        "streams" => [
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } },
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-select_streams")
          capture_result(video_output)
        else
          capture_result(track_output)
        end
      end

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-text-subtitles.mkv",
        headers: {},
        start_seconds: 120,
        subtitle_stream: "3"
      )

      expect(command).not_to include("-filter_complex")
      expect(argument_pairs(command)).to include([ "-map", "0:v:0" ])
      expect(argument_pairs(command)).to include([ "-c:v", "libx264" ])
      expect(argument_pairs(command)).not_to include([ "-c:v", "copy" ])
    end

    it "uses VideoToolbox hardware encoding when available" do
      described_class.instance_variable_set(:@videotoolbox_available, true)
      output = {
        "streams" => [
          { "codec_name" => "hevc", "width" => 3840, "height" => 2160, "pix_fmt" => "yuv420p10le" }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-4k-hevc.mkv",
        headers: {},
        start_seconds: 0
      )

      expect(argument_pairs(command)).to include(
        [ "-c:v", "h264_videotoolbox" ],
        [ "-b:v", "4000k" ],
        [ "-profile:v", "high" ],
        [ "-level:v", "4.0" ]
      )
      expect(argument_pairs(command)).not_to include([ "-c:v", "libx264" ])
    end

    it "enforces the AVC compatibility contract on custom hardware encoders" do
      output = {
        "streams" => [
          { "codec_name" => "hevc", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p10le" }
        ]
      }.to_json
      allow(described_class).to receive(:capture_command).and_return(capture_result(output))
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("FFMPEG_ENCODER").and_return("h264_nvenc -preset p7")

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-hevc.mkv",
        headers: {},
        start_seconds: 0
      )

      expect(argument_pairs(command)).to include(
        [ "-c:v", "h264_nvenc" ],
        [ "-profile:v", "high" ],
        [ "-level:v", "4.0" ]
      )
    end
  end

  describe "HLS output spec" do
    let(:video_output) do
      { "streams" => [ { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" } ] }.to_json
    end

    before do
      allow(described_class).to receive(:capture_command).and_return(capture_result(video_output))
    end

    it "appends HLS output args when output_spec is :hls" do
      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video.mkv",
        headers: {},
        start_seconds: 0,
        output_spec: :hls,
        segment_dir: "/tmp/hls/session1"
      )

      expect(argument_pairs(command)).to include([ "-f", "hls" ])
      expect(argument_pairs(command)).to include([ "-hls_time", "4" ])
      expect(argument_pairs(command)).to include([ "-hls_playlist_type", "event" ])
      expect(argument_pairs(command)).to include([ "-hls_segment_type", "mpegts" ])
      expect(argument_pairs(command)).to include([ "-hls_flags", "temp_file" ])
      expect(argument_pairs(command)).to include([ "-hls_segment_filename", "/tmp/hls/session1/%d.ts" ])
      expect(argument_pairs(command)).to include([ "-readrate", "1.0" ])
      expect(argument_pairs(command)).to include([ "-readrate_initial_burst", "30" ])
      expect(command).to include("/tmp/hls/session1/playlist.m3u8")
      # fMP4 output must NOT appear on the HLS path
      expect(command).not_to include("pipe:1")
      expect(argument_pairs(command)).not_to include([ "-movflags", anything ])
    end

    it "defaults to fMP4 output when output_spec is omitted" do
      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video.mkv",
        headers: {},
        start_seconds: 0
      )

      expect(argument_pairs(command)).to include([ "-f", "mp4" ])
      expect(command).to include("pipe:1")
      expect(command).not_to include("playlist.m3u8")
    end

    it "raises ArgumentError when :hls is requested without segment_dir" do
      expect {
        described_class.send(:build_ffmpeg_command,
          "https://example.test/video.mkv",
          headers: {},
          start_seconds: 0,
          output_spec: :hls
        )
      }.to raise_error(ArgumentError, /segment_dir is required for HLS output/)
    end

    it "preserves audio/video selection on the HLS path" do
      track_output = {
        "streams" => [
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } }
        ]
      }.to_json
      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        cmd.include?("-select_streams") ? capture_result(video_output) : capture_result(track_output)
      end

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video.mkv",
        headers: {},
        start_seconds: 0,
        audio_stream: "1",
        output_spec: :hls,
        segment_dir: "/tmp/hls/abc"
      )

      expect(argument_pairs(command)).to include([ "-map", "0:1" ])
      expect(argument_pairs(command)).to include([ "-c:a", "aac" ])
      expect(argument_pairs(command)).to include([ "-af", "aresample=async=1000:first_pts=0" ])
      expect(argument_pairs(command)).not_to include([ "-c:a", "copy" ])
      expect(argument_pairs(command)).to include([ "-f", "hls" ])
    end

    it "re-encodes non-AAC audio sources to AAC with continuous clock correction" do
      track_output = {
        "streams" => [
          { "index" => 1, "codec_type" => "audio", "codec_name" => "ac3", "channels" => 6, "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } }
        ]
      }.to_json
      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        cmd.include?("-select_streams") ? capture_result(video_output) : capture_result(track_output)
      end

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-ac3.mkv",
        headers: {},
        start_seconds: 0,
        audio_stream: "1",
        segment_dir: "/tmp/hls/abc"
      )

      pairs = argument_pairs(command)
      expect(pairs).to include([ "-c:a", "aac" ])
      expect(pairs).to include([ "-b:a", "192k" ])
      expect(pairs).to include([ "-af", "aresample=async=1000:first_pts=0" ])
      expect(pairs).not_to include([ "-c:a", "copy" ])
    end

    it "applies generated input timestamps before -i on both output paths" do
      hls_command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video.mkv",
        headers: {},
        start_seconds: 0,
        output_spec: :hls,
        segment_dir: "/tmp/hls/timestamps"
      )
      fmp4_command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video.mkv",
        headers: {},
        start_seconds: 0
      )

      [ hls_command, fmp4_command ].each do |command|
        expect(argument_pairs(command)).to include([ "-fflags", "+genpts" ])
        expect(command.index("-fflags")).to be < command.index("-i")
      end
    end
  end

  describe ".extract_subtitles_to_vtt" do
    it "extracts text subtitle cues from ffprobe packets before falling back to ffmpeg" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json
      packet_output = {
        "packets" => [
          {
            "pts_time" => "121.500000",
            "duration_time" => "2.500000",
            "data" => "\n00000000: 4865 6c6c 6f20 7061 636b 6574            Hello packet\n"
          }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-show_data")
          expect(argument_pairs(cmd)).to include([ "-select_streams", "3" ])
          expect(argument_pairs(cmd)).to include([ "-read_intervals", "120.0%+5" ])
          capture_result(packet_output)
        else
          capture_result(track_output)
        end
      end
      expect(described_class).not_to receive(:capture_subtitle_stdout_result)

      output = described_class.extract_subtitles_to_vtt(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120,
        duration_seconds: 5
      )

      expect(output).to include("00:02:01.500 --> 00:02:04.000")
      expect(output).to include("Hello packet")
    end

    it "extracts the selected text subtitle stream from the requested start position" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-show_data")
          capture_result("", success: false)
        else
          capture_result(track_output)
        end
      end
      allow(described_class).to receive(:capture_subtitle_stdout_result) do |cmd|
        expect(cmd).to include("-ss", "120.0")
        expect(argument_pairs(cmd)).to include([ "-t", "5" ])
        expect(cmd).to include("-vn", "-an", "-dn")
        expect(argument_pairs(cmd)).to include([ "-map", "0:3" ])
        expect(argument_pairs(cmd)).to include([ "-c:s", "webvtt" ])
        described_class::SubtitleExtractionResult.new(
          status: :ok,
          vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n",
          cue_count: 1,
          source: :ffmpeg
        )
      end

      output = described_class.extract_subtitles_to_vtt(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120,
        duration_seconds: 3
      )

      expect(output).to start_with("WEBVTT")
    end

    it "clamps large subtitle windows before extracting packets" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json
      packet_output = {
        "packets" => [
          {
            "pts_time" => "121.500000",
            "duration_time" => "2.500000",
            "data" => "\n00000000: 4865 6c6c 6f20 7061 636b 6574            Hello packet\n"
          }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-show_data")
          expect(argument_pairs(cmd)).to include([ "-read_intervals", "120.0%+60" ])
          capture_result(packet_output)
        else
          capture_result(track_output)
        end
      end

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120,
        duration_seconds: 600
      )

      expect(result.status).to eq(:ok)
      expect(result.source).to eq(:ffprobe_packets)
    end

    it "reports an empty subtitle window without falling back to ffmpeg when ffprobe finds no packets" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json
      packet_output = { "packets" => [] }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-show_data")
          capture_result(packet_output)
        else
          capture_result(track_output)
        end
      end
      expect(described_class).not_to receive(:capture_subtitle_stdout_result)

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120
      )

      expect(result.status).to eq(:empty_window)
      expect(result.source).to eq(:ffprobe_packets)
      expect(result.vtt).to eq("")
    end

    it "reports a packet timeout as retryable without falling back to the slower extractor" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng", "title" => "forced" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **kwargs|
        if cmd.include?("-show_data")
          expect(kwargs[:timeout_seconds]).to eq(described_class::SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS)
          capture_result("", timed_out: true)
        else
          capture_result(track_output)
        end
      end
      expect(described_class).not_to receive(:capture_subtitle_stdout_result)

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120
      )

      expect(result.status).to eq(:timeout)
      expect(result.source).to eq(:ffprobe_packets)
      expect(result.diagnostic).to eq("ffprobe packet extraction timed out")
    end

    it "falls back to ffmpeg when ffprobe packets cannot be decoded into cues" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json
      packet_output = {
        "packets" => [
          {
            "pts_time" => "121.500000",
            "duration_time" => "2.500000",
            "data" => ""
          }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-show_data")
          capture_result(packet_output)
        else
          capture_result(track_output)
        end
      end
      allow(described_class).to receive(:capture_subtitle_stdout_result).and_return(
        described_class::SubtitleExtractionResult.new(
          status: :ok,
          vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nFallback\n",
          cue_count: 1,
          source: :ffmpeg
        )
      )

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120
      )

      expect(result.status).to eq(:ok)
      expect(result.source).to eq(:ffmpeg)
      expect(result.vtt).to include("Fallback")
    end

    it "falls back to ffmpeg when ffprobe packet JSON cannot be parsed" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **_kwargs|
        if cmd.include?("-show_data")
          capture_result("{")
        else
          capture_result(track_output)
        end
      end
      allow(described_class).to receive(:capture_subtitle_stdout_result).and_return(
        described_class::SubtitleExtractionResult.new(
          status: :ok,
          vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nFallback\n",
          cue_count: 1,
          source: :ffmpeg
        )
      )

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120
      )

      expect(result.status).to eq(:ok)
      expect(result.source).to eq(:ffmpeg)
      expect(result.vtt).to include("Fallback")
    end

    it "rejects invalid subtitle stream identifiers before probing tracks" do
      expect(described_class).not_to receive(:probe_media_tracks)

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "../3",
        start_seconds: 120
      )

      expect(result.status).to eq(:invalid_stream)
      expect(result.diagnostic).to eq("invalid subtitle stream")
    end

    it "reports missing subtitle streams" do
      track_output = {
        "streams" => [
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "tags" => { "language" => "eng" }, "disposition" => { "default" => 1 } }
        ]
      }.to_json
      allow(described_class).to receive(:capture_command).and_return(capture_result(track_output))

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120
      )

      expect(result.status).to eq(:unsupported_track)
      expect(result.diagnostic).to eq("subtitle stream was not found")
    end

    it "reports unsupported bitmap subtitle streams for VTT extraction" do
      track_output = {
        "streams" => [
          { "index" => 4, "codec_type" => "subtitle", "codec_name" => "hdmv_pgs_subtitle", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(track_output))

      result = described_class.extract_subtitles(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "4",
        start_seconds: 120
      )

      expect(result.status).to eq(:unsupported_track)
    end

    it "rejects header-only WebVTT output" do
      expect(described_class.send(:webvtt_has_cues?, "WEBVTT\n\n")).to be(false)
      expect(described_class.send(:webvtt_has_cues?, "WEBVTT\n\n00:03.217 --> 00:05.177\nHello\n")).to be(true)
    end

    it "waits for a subtitle process to finish the requested output window" do
      command = [
        RbConfig.ruby,
        "-e",
        "$stdout.write(\"WEBVTT\\n\\n00:03.217 --> 00:05.177\\nHello\\n\"); " \
          "$stdout.flush; sleep 0.2; " \
          "$stdout.write(\"\\n00:06.217 --> 00:08.177\\nLater\\n\"); $stdout.flush"
      ]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = described_class.send(:capture_subtitle_stdout_result, command)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.2
      expect(result.vtt).to include("Hello")
      expect(result.vtt).to include("Later")
    end

    it "returns cue output from a subtitle process that times out after writing cues" do
      stub_const("Media::Transcoder::SUBTITLE_EXTRACTION_TIMEOUT_SECONDS", 0.5)
      command = [
        RbConfig.ruby,
        "-e",
        "$stdout.write(\"WEBVTT\\n\\n00:03.217 --> 00:05.177\\nHello\\n\"); $stdout.flush; sleep 10"
      ]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = described_class.send(:capture_subtitle_stdout_result, command)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(result.vtt).to include("Hello")
    end
  end

  describe "process cleanup" do
    it "times out captured commands without Open3 reader threads" do
      command = [ RbConfig.ruby, "-e", "sleep 10" ]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = described_class.send(:capture_command, command, timeout_seconds: 0.1)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(result.timed_out).to be(true)
      expect(result.status).to be_nil
    end

    it "force kills a process group that ignores TERM" do
      pid = Process.spawn(
        RbConfig.ruby,
        "-e",
        "trap('TERM') {}; sleep 60",
        out: File::NULL,
        err: File::NULL,
        pgroup: true
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      described_class.send(:kill_process_group, pid)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(process_alive?(pid)).to be(false)
    ensure
      if pid && process_alive?(pid)
        begin
          Process.kill("KILL", -pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
        end
      end
    end

    it "reaps an already-exited child when its process group is gone" do
      allow(described_class).to receive(:signal_group).with(123, "CONT").and_return(false)
      allow(described_class).to receive(:signal_group).with(123, "TERM").and_return(false)
      expect(described_class).to receive(:waitpid_safely).with(123)

      described_class.send(:kill_process_group, 123)
    end
  end

    it "waits for a gated HLS stderr drain before closing the reader" do
      stderr_reader, stderr_writer = IO.pipe
      stderr_buffer = +""
      stderr_mutex = Mutex.new
      stderr_thread = Thread.new do
        sleep 0.05
        loop do
          chunk = stderr_reader.readpartial(4096)
          stderr_mutex.synchronize { stderr_buffer << chunk }
        end
      rescue EOFError, IOError, Errno::EBADF
      end
      process = described_class::HlsProcess.new(
        pid: 123,
        stderr_io: stderr_reader,
        stderr_thread: stderr_thread,
        stderr_buffer: stderr_buffer,
        stderr_mutex: stderr_mutex
      )
      stderr_writer.write("complete diagnostic sentinel")
      stderr_writer.close

      process.close_diagnostics

      expect(process.diagnostic).to eq("complete diagnostic sentinel")
      expect(stderr_reader).to be_closed
    ensure
      stderr_writer&.close unless stderr_writer&.closed?
      stderr_reader&.close unless stderr_reader&.closed?
      stderr_thread&.join(1)
    end

    it "keeps HLS stderr draining after non-blocking startup" do
      script = <<~RUBY
        $stderr.sync = true
        sleep 0.1
        warn "late diagnostic"
      RUBY
      allow(described_class).to receive(:build_ffmpeg_command)
        .and_return([ RbConfig.ruby, "-e", script ])

      Dir.mktmpdir do |dir|
        process = described_class.transcode_to_hls(
          "https://example.test/video.mkv",
          segment_dir: dir,
          wait_for_first_segment: false
        )
        _, status = Process.waitpid2(process.pid)
        process.close_diagnostics

        expect(status).to be_success
        expect(process.diagnostic).to include("late diagnostic")
      end
    end

  describe ".transcode_to_fmp4 stall detection" do
    it "raises TranscodeError when ffmpeg produces no data before the first-data timeout" do
      stub_const("Media::Transcoder::FIRST_DATA_TIMEOUT_SECONDS", 0.5)

      # A process that produces nothing on stdout — simulates ffmpeg
      # hanging on probe/analysis of a bad remote URL.
      script = "sleep 10"
      command = [ RbConfig.ruby, "-e", script ]

      expect {
        described_class.send(:transcode_to_fmp4_internal, command) { |_chunk| }
      }.to raise_error(
        Media::Transcoder::TranscodeError,
        /timed out.*waiting for first data/
      )
    end

    it "raises after streamed output when ffmpeg exits unsuccessfully" do
      script = <<~RUBY
        $stdout.sync = true
        $stdout.write("fragment")
        warn "upstream terminated"
        exit 7
      RUBY
      command = [ RbConfig.ruby, "-e", script ]
      received = +""

      expect {
        described_class.send(:transcode_to_fmp4_internal, command) { |chunk| received << chunk }
      }.to raise_error(
        Media::Transcoder::TranscodeError,
        /status 7.*upstream terminated/
      )
      expect(received).to eq("fragment")
    end

    it "does not time out once ffmpeg has produced data (bursts are normal)" do
      stub_const("Media::Transcoder::FIRST_DATA_TIMEOUT_SECONDS", 1)

      # Writes a chunk, pauses, writes more — simulates ffmpeg's bursty
      # transcoding output. The backend must not kill the process during
      # the pause; only the frontend watchdog detects true playback stalls.
      script = <<~RUBY
        $stdout.sync = true
        $stdout.write("a" * 1024)
        sleep 2
        $stdout.write("b" * 1024)
      RUBY
      command = [ RbConfig.ruby, "-e", script ]

      chunks = []
      described_class.send(:transcode_to_fmp4_internal, command) { |chunk| chunks << chunk }

      expect(chunks.join).to eq("a" * 1024 + "b" * 1024)
    end

    it "delivers every byte through a one-chunk bounded queue" do
      stub_const("Media::Transcoder::STREAM_QUEUE_MAX_CHUNKS", 1)
      payload = "x" * (Media::Transcoder::STREAM_CHUNK_BYTES * 4)
      script = "$stdout.binmode; 4.times { $stdout.write('x' * #{Media::Transcoder::STREAM_CHUNK_BYTES}) }"
      command = [ RbConfig.ruby, "-e", script ]

      received = +""
      described_class.send(:transcode_to_fmp4_internal, command) do |chunk|
        received << chunk
        sleep 0.01
      end

      expect(received).to eq(payload)
    end
  end

  def argument_pairs(command)
    command.each_cons(2).to_a
  end

  def capture_result(stdout, success: true, timed_out: false)
    status = timed_out ? nil : instance_double(Process::Status, success?: success)
    described_class::CommandCaptureResult.new(
      stdout: stdout,
      stderr: "",
      status: status,
      timed_out: timed_out
    )
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
