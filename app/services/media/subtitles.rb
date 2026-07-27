# frozen_string_literal: true

module Media
  class Subtitles
    ExtractionResult = Transcoder::SubtitleExtractionResult
    DEFAULT_WINDOW_SECONDS = Transcoder::SUBTITLE_EXTRACTION_WINDOW_SECONDS
    MIN_WINDOW_SECONDS = Transcoder::MIN_SUBTITLE_EXTRACTION_WINDOW_SECONDS
    MAX_WINDOW_SECONDS = Transcoder::MAX_SUBTITLE_EXTRACTION_WINDOW_SECONDS

    class << self
      def extract(input_url, headers: {}, subtitle_stream: nil, start_seconds: 0, duration_seconds: DEFAULT_WINDOW_SECONDS)
        Transcoder.extract_subtitles(
          input_url,
          headers: headers,
          subtitle_stream: subtitle_stream,
          start_seconds: start_seconds,
          duration_seconds: duration_seconds
        )
      end

      def selectable_tracks(tracks)
        Transcoder.selectable_subtitle_tracks(tracks)
      end

      def result(**attributes)
        ExtractionResult.new(**attributes)
      end
    end
  end
end
