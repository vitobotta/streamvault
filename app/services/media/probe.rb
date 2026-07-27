# frozen_string_literal: true

module Media
  class Probe
    MAX_COPY_VIDEO_WIDTH = Transcoder::MAX_COPY_VIDEO_WIDTH
    MAX_COPY_VIDEO_HEIGHT = Transcoder::MAX_COPY_VIDEO_HEIGHT
    SAFE_H264_PIXEL_FORMATS = Transcoder::SAFE_H264_PIXEL_FORMATS

    class << self
      def duration(input_url, headers: {})
        Transcoder.probe_duration(input_url, headers: headers)
      end

      def profile(input_url, headers: {})
        Transcoder.probe_media_info(input_url, headers: headers)
      end

      def tracks(input_url, headers: {})
        Transcoder.probe_media_tracks(input_url, headers: headers)
      end

      def remux_seek(input_url, target_seconds:, headers: {})
        Transcoder.probe_remux_seek(input_url, target_seconds: target_seconds, headers: headers)
      end
    end
  end
end
