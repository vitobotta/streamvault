require 'rails_helper'

RSpec.describe TranscodeService do
  before do
    described_class.instance_variable_set(:@probe_cache, {})
  end

  describe ".probe_duration" do
    it "uses the longest valid duration from ffprobe output" do
      status = instance_double(Process::Status, success?: true)
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

      allow(Open3).to receive(:capture3).and_return([ output, "", status ])

      duration = described_class.probe_duration("https://example.test/video-valid-duration.mkv")

      expect(duration).to eq(8885.5)
    end

    it "rejects tiny fragment durations" do
      status = instance_double(Process::Status, success?: true)
      output = {
        "format" => { "duration" => "0.100000" },
        "streams" => [ { "duration" => "0.200000" } ]
      }.to_json

      allow(Open3).to receive(:capture3).and_return([ output, "", status ])

      duration = described_class.probe_duration("https://example.test/video-fragment-duration.mkv")

      expect(duration).to eq(0)
    end
  end

  describe ".probe_media_tracks" do
    it "returns canonical audio and subtitle track metadata" do
      status = instance_double(Process::Status, success?: true)
      output = {
        "streams" => [
          { "index" => 0, "codec_type" => "video", "codec_name" => "h264" },
          { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "channels" => 6, "tags" => { "language" => "eng", "title" => "Main" }, "disposition" => { "default" => 1 } },
          { "index" => 2, "codec_type" => "audio", "codec_name" => "ac3", "channels" => 2, "tags" => { "language" => "fre" }, "disposition" => { "default" => 0 } },
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "spa" }, "disposition" => { "default" => 0 } },
          { "index" => 4, "codec_type" => "subtitle", "codec_name" => "hdmv_pgs_subtitle", "tags" => { "language" => "ger" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(Open3).to receive(:capture3).and_return([ output, "", status ])

      tracks = described_class.probe_media_tracks("https://example.test/video-tracks.mkv")

      expect(tracks[:audio].map { |track| track.slice(:index, :language, :language_label, :channels, :default) }).to eq([
        { index: 1, language: "ENG", language_label: "English", channels: 6, default: true },
        { index: 2, language: "FRENCH", language_label: "French", channels: 2, default: false }
      ])
      expect(tracks[:subtitles].map { |track| track.slice(:index, :language, :text_supported) }).to eq([
        { index: 3, language: "SPANISH", text_supported: true },
        { index: 4, language: "GERMAN", text_supported: false }
      ])
    end
  end

  describe "ffmpeg command selection" do
    it "copies browser-safe H.264 video" do
      status = instance_double(Process::Status, success?: true)
      output = {
        "streams" => [
          { "codec_name" => "h264", "width" => 1920, "height" => 1080, "pix_fmt" => "yuv420p" }
        ]
      }.to_json

      allow(Open3).to receive(:capture3).and_return([ output, "", status ])

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
      status = instance_double(Process::Status, success?: true)
      output = {
        "streams" => [
          { "codec_name" => "hevc", "width" => 3840, "height" => 2160, "pix_fmt" => "yuv420p10le" }
        ]
      }.to_json

      allow(Open3).to receive(:capture3).and_return([ output, "", status ])

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
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return([ "", "probe failed", status ])

      command = described_class.send(:build_ffmpeg_command,
        "https://example.test/video-unknown.mkv",
        headers: {},
        start_seconds: 0
      )

      expect(argument_pairs(command)).to include([ "-c:v", "libx264" ])
      expect(argument_pairs(command)).not_to include([ "-c:v", "copy" ])
    end

    it "maps the default language audio stream before other preferred audio streams" do
      status = instance_double(Process::Status, success?: true)
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

      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.include?("-select_streams")
          [ video_output, "", status ]
        else
          [ track_output, "", status ]
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
      status = instance_double(Process::Status, success?: true)
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

      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.include?("-select_streams")
          [ video_output, "", status ]
        else
          [ track_output, "", status ]
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
      status = instance_double(Process::Status, success?: true)
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

      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.include?("-select_streams")
          [ video_output, "", status ]
        else
          [ track_output, "", status ]
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
      status = instance_double(Process::Status, success?: true)
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

      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.include?("-show_data")
          expect(argument_pairs(cmd)).to include([ "-select_streams", "3" ])
          expect(argument_pairs(cmd)).to include([ "-read_intervals", "120.0%+360" ])
          [ packet_output, "", status ]
        else
          [ track_output, "", status ]
        end
      end
      expect(described_class).not_to receive(:capture_subtitle_stdout)

      output = described_class.extract_subtitles_to_vtt(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120
      )

      expect(output).to include("00:02:01.500 --> 00:02:04.000")
      expect(output).to include("Hello packet")
    end

    it "extracts the selected text subtitle stream from the requested start position" do
      status = instance_double(Process::Status, success?: true)
      track_output = {
        "streams" => [
          { "index" => 3, "codec_type" => "subtitle", "codec_name" => "subrip", "tags" => { "language" => "eng" }, "disposition" => { "default" => 0 } }
        ]
      }.to_json

      allow(Open3).to receive(:capture3).and_return([ track_output, "", status ])
      allow(described_class).to receive(:capture_subtitle_stdout) do |cmd|
        expect(cmd).to include("-ss", "120.0")
        expect(argument_pairs(cmd)).to include([ "-t", "360" ])
        expect(cmd).to include("-vn", "-an", "-dn")
        expect(argument_pairs(cmd)).to include([ "-map", "0:3" ])
        expect(argument_pairs(cmd)).to include([ "-c:s", "webvtt" ])
        "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n"
      end

      output = described_class.extract_subtitles_to_vtt(
        "https://example.test/video-subtitles.mkv",
        subtitle_stream: "3",
        start_seconds: 120
      )

      expect(output).to start_with("WEBVTT")
    end

    it "rejects header-only WebVTT output" do
      expect(described_class.send(:webvtt_has_cues?, "WEBVTT\n\n")).to be(false)
      expect(described_class.send(:webvtt_has_cues?, "WEBVTT\n\n00:03.217 --> 00:05.177\nHello\n")).to be(true)
    end

    it "returns cue output from a subtitle process that keeps running after writing cues" do
      command = [
        RbConfig.ruby,
        "-e",
        "$stdout.write(\"WEBVTT\\n\\n00:03.217 --> 00:05.177\\nHello\\n\"); $stdout.flush; sleep 10"
      ]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      output = described_class.send(:capture_subtitle_stdout, command)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      expect(output).to include("Hello")
    end
  end

  describe "process cleanup" do
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

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
