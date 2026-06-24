require 'rails_helper'

RSpec.describe TranscodeService do
  before do
    described_class.instance_variable_set(:@probe_cache, {})
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
    it "copies browser-safe H.264 video" do
      output = {
        "streams" => [
          { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command).and_return(capture_result(output))

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-h264-1080p.mkv",
        headers: { "Authorization" => "Bearer token" },
        start_seconds: 42.5
      )

      expect(argument_pairs(command)).to include([ "-c:v", "copy" ])
      expect(argument_pairs(command)).to include([ "-ss", "42.5" ])
      expect(argument_pairs(command)).to include([ "-headers", "Authorization: Bearer token\r\n" ])
      expect(command).not_to include("libx264")
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
      expect(argument_pairs(command)).to include([ "-c:v", "copy" ])
      expect(argument_pairs(command)).not_to include([ "-c:v", "libx264" ])
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
      expect(described_class).not_to receive(:capture_subtitle_stdout)

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

    it "reports a packet timeout as an empty subtitle window without falling back to ffmpeg" do
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng", "title" => "forced" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(described_class).to receive(:capture_command) do |cmd, **kwargs|
        if cmd.include?("-show_data")
          expect(kwargs[:timeout_seconds]).to eq(described_class::FORCED_SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS)
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

      expect(result.status).to eq(:empty_window)
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

      output = described_class.send(:capture_subtitle_stdout, command)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.2
      expect(output).to include("Hello")
      expect(output).to include("Later")
    end

    it "returns cue output from a subtitle process that times out after writing cues" do
      stub_const("TranscodeService::SUBTITLE_EXTRACTION_TIMEOUT_SECONDS", 0.5)
      command = [
        RbConfig.ruby,
        "-e",
        "$stdout.write(\"WEBVTT\\n\\n00:03.217 --> 00:05.177\\nHello\\n\"); $stdout.flush; sleep 10"
      ]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      output = described_class.send(:capture_subtitle_stdout, command)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(output).to include("Hello")
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
