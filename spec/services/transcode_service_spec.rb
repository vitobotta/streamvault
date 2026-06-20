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
  end

  def argument_pairs(command)
    command.each_cons(2).to_a
  end
end
