# frozen_string_literal: true

# Remuxes/transcodes streams via FFmpeg for browser playback.
# MKV → fMP4, DTS/TrueHD → AAC. Video is copied, not re-encoded.
class TranscodeService
  FFMPEG_PATH = "ffmpeg"
  # Fragmented MP4 flags: empty_moov = streamable immediately, frag_keyframe = fragment at keyframes
  FMP4_FLAGS = "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets"

  def self.needs_transcode?(filename)
    return false if filename.blank?
    ext = File.extname(filename).delete(".").downcase
    # Need transcode for non-MP4/WEBM containers
    return true unless %w[mp4 webm].include?(ext)
    false
  end

  # Returns an IO-like object that streams the transcoded fMP4
  def self.transcode_to_fmp4(input_url, &block)
    cmd = [
      FFMPEG_PATH,
      "-loglevel", "error",
      "-i", input_url,
      "-c:v", "copy",           # Copy video stream (no re-encoding)
      "-c:a", "aac",            # Transcode audio to AAC
      "-b:a", "192k",           # Audio bitrate
      "-ac", "2",               # Stereo output
      "-f", "mp4",              # MP4 container
      "-movflags", FMP4_FLAGS,  # Fragmented MP4 for streaming
      "-preset", "ultrafast",   # Fastest encoding preset
      "pipe:1"                  # Output to stdout
    ]

    IO.popen(cmd, "rb", err: "/dev/null") do |io|
      while (chunk = io.read(16_384))
        yield chunk
      end
    end
  end
end
