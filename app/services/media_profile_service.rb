# frozen_string_literal: true

class MediaProfileService
  MP4_EXTENSIONS = %w[.mp4 .m4v .mov].freeze
  AAC_CODEC = "aac"
  HEVC_CODECS = %w[hevc h265].freeze
  REMUX_COMPATIBLE_CODECS = %w[h264 hevc h265].freeze

  def initialize(input_url:, filename:, headers:, subtitle_search:, logger: Rails.logger)
    @input_url = input_url
    @filename = filename.to_s.downcase
    @headers = headers
    @subtitle_search = subtitle_search
    @logger = logger
  end

  def call
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    media_info_thread = Thread.new { Media::Probe.profile(@input_url, headers: @headers) }
    external_subtitles_thread = Thread.new { ExternalSubtitleService.search(**@subtitle_search) }
    media_info, external_subtitles = [ media_info_thread, external_subtitles_thread ].map(&:value)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    @logger.info("[MediaProfileService] parallel metadata ready in #{elapsed.round(2)}s")

    tracks = media_info.fetch(:media_tracks)
    video_stream = media_info.fetch(:video_stream)
    subtitles = Media::Subtitles.selectable_tracks(tracks.fetch(:subtitles, []) + external_subtitles)

    ServiceResult.success(
      MediaProfile.new(
        audio: tracks.fetch(:audio, []),
        subtitles: subtitles,
        video_codec: video_stream[:codec_name].to_s.downcase,
        video_codec_tag: video_stream[:codec_tag].to_s.downcase,
        video_width: video_stream[:width],
        video_height: video_stream[:height],
        video_pix_fmt: video_stream[:pix_fmt],
        direct_playable: direct_playable?(tracks, video_stream),
        remux_direct_playable: remux_direct_playable?(video_stream)
      )
    )
  rescue StandardError => e
    @logger.error("[MediaProfileService] profile failed: #{e.class}: #{e.message}")
    ServiceResult.failure("Unable to inspect media")
  end

  private

  def direct_playable?(tracks, video_stream)
    return false unless MP4_EXTENSIONS.any? { |extension| @filename.end_with?(extension) }
    return false unless direct_play_video?(video_stream)

    audio_tracks = tracks.fetch(:audio, [])
    return true if audio_tracks.empty?

    default_audio = audio_tracks.find { |track| track[:default] } || audio_tracks.first
    default_audio[:codec].to_s.downcase == AAC_CODEC
  end

  def direct_play_video?(video_stream)
    return false unless video_stream.is_a?(Hash)

    codec = video_stream[:codec_name].to_s.downcase
    width = video_stream[:width].to_i
    height = video_stream[:height].to_i
    pixel_format = video_stream[:pix_fmt].to_s
    return false unless width.positive? && height.positive?
    return HEVC_CODECS.include?(codec) unless codec == "h264"

    width <= Media::Probe::MAX_COPY_VIDEO_WIDTH &&
      height <= Media::Probe::MAX_COPY_VIDEO_HEIGHT &&
      Media::Probe::SAFE_H264_PIXEL_FORMATS.include?(pixel_format)
  end

  def remux_direct_playable?(video_stream)
    REMUX_COMPATIBLE_CODECS.include?(video_stream[:codec_name].to_s.downcase)
  end
end
