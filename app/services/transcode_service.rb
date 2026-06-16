# frozen_string_literal: true

# Remuxes/transcodes streams via FFmpeg for browser playback.
# Video is copied (no re-encoding), audio → AAC.
class TranscodeService
  FFMPEG_PATH = "ffmpeg"
  FMP4_FLAGS = "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets"

  # Always transcode — guarantees audio works for all streams
  def self.needs_transcode?(_filename)
    true
  end

  # Stream transcoded fMP4 from FFmpeg
  # Accepts optional headers hash for auth
  def self.transcode_to_fmp4(input_url, headers: {}, &block)
    # Build FFmpeg headers string
    header_str = headers.map { |k, v| "#{k}: #{v}" }.join("\r\n")

    cmd = [FFMPEG_PATH, "-loglevel", "error"]

    # Add headers if present (for RealDebrid auth)
    if header_str.present?
      cmd += ["-headers", header_str + "\r\n"]
    end

    cmd += [
      "-i", input_url,
      "-c:v", "copy",           # Copy video (no re-encoding)
      "-c:a", "aac",            # Transcode audio to AAC
      "-b:a", "192k",
      "-ac", "2",               # Stereo
      "-f", "mp4",
      "-movflags", FMP4_FLAGS,  # Fragmented MP4 for streaming
      "pipe:1"                  # Output to stdout
    ]

    IO.popen(cmd, "rb", err: "/dev/null") do |io|
      while (chunk = io.read(32_768))
        yield chunk
      end
    end
  end
end
