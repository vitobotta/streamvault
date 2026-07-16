# frozen_string_literal: true

class TranscodeTracksController < ApplicationController
  include StreamUrlValidation

  MP4_EXTENSIONS = %w[.mp4 .m4v .mov].freeze
  AAC_CODEC = "aac"
  HEVC_CODECS = %w[hevc h265].freeze

  before_action :authenticate_user!

  def show
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { audio: [], subtitles: [] }, status: :bad_request
      return
    end

    tracks = TranscodeService.probe_media_tracks(input_url, headers: transcode_headers)
    external_subtitles = ExternalSubtitleService.search(
      imdb_id: params[:imdb_id],
      type: params[:type],
      season: params[:season],
      episode: params[:episode],
      title: params[:title],
      filename: params[:filename],
      preferred_languages: current_user.preferred_stream_languages,
      default_language: current_user.default_stream_language
    )

    subtitles = TranscodeService.selectable_subtitle_tracks(tracks[:subtitles] + external_subtitles)
    video_stream = probe_video_stream(input_url)
    render json: tracks.merge(
      subtitles: subtitles,
      video_codec: video_stream[:codec_name].to_s.downcase,
      video_codec_tag: video_stream[:codec_tag].to_s.downcase,
      video_width: video_stream[:width],
      video_height: video_stream[:height],
      video_pix_fmt: video_stream[:pix_fmt],
      direct_playable: direct_playable?(input_url, tracks, video_stream),
      direct_stream_url: direct_stream_url(input_url),
      remux_direct_playable: remux_direct_playable?(video_stream),
      remux_direct_url: remux_direct_url(input_url)
    )
  end

  # Return a keyframe-aligned remux start plus the short local pre-roll
  # the browser must skip to land on the exact requested position.
  def seek
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { copy_safe: false }, status: :bad_request
      return
    end

    plan = TranscodeService.probe_remux_seek(
      input_url,
      target_seconds: params[:start_seconds],
      headers: transcode_headers
    )

    if plan
      render json: plan.merge(copy_safe: true)
    else
      render json: { copy_safe: false }
    end
  end

  private

  def transcode_headers
    return {} unless current_user.has_realdebrid_key?

    { "Authorization" => "Bearer #{current_user.realdebrid_api_key}" }
  end

  def probe_video_stream(input_url)
    TranscodeService.probe_video_stream(input_url, headers: transcode_headers)
  end

  # Can the file be played directly by the browser via <video src>?
  # Direct play uses the native <video> element + /direct_stream proxy (no
  # ffmpeg, no MSE).  The browser downloads at network speed and handles
  # its own buffering, so this is the fastest path — same as Stremio.
  #
  # Requirements:
  #   1. Container is MP4 (.mp4/.m4v/.mov) — the browser plays these
  #      natively without MSE.
  #   2. Video is safe H.264, or HEVC that the client confirms its
  #      platform can decode natively.
  #   3. The default audio track is AAC (or audio is absent).
  #
  # NOT required: B-frame-free. The native <video> element handles
  # B-frames; that constraint applies only to MSE SourceBuffer.
  def direct_playable?(input_url, tracks, video_stream = nil)
    filename = params[:filename].to_s.downcase
    return false unless MP4_EXTENSIONS.any? { |ext| filename.end_with?(ext) }

    video_stream ||= probe_video_stream(input_url)
    return false unless direct_play_video?(video_stream)

    audio_tracks = tracks[:audio]
    return true if audio_tracks.empty?

    default_audio = audio_tracks.find { |track| track[:default] } || audio_tracks.first
    default_audio[:codec] == AAC_CODEC
  end

  # Identify a native-video candidate. H.264 constraints remain
  # conservative; HEVC support is decided by the actual browser because
  # it varies by platform and installed decoder.
  def direct_play_video?(video_stream)
    return false unless video_stream.is_a?(Hash)

    codec = video_stream[:codec_name].to_s.downcase
    width = video_stream[:width].to_i
    height = video_stream[:height].to_i
    pix_fmt = video_stream[:pix_fmt].to_s
    return false unless width.positive? && height.positive?

    return HEVC_CODECS.include?(codec) unless codec == "h264"

    width <= TranscodeService::MAX_COPY_VIDEO_WIDTH &&
      height <= TranscodeService::MAX_COPY_VIDEO_HEIGHT &&
      TranscodeService::SAFE_H264_PIXEL_FORMATS.include?(pix_fmt)
  end

  def direct_stream_url(input_url)
    "/direct_stream?url=#{CGI.escape(input_url)}"
  end

  # Remux direct play is eligible when the video codec is H.264 or HEVC,
  # regardless of container, B-frames, resolution, or pixel format.
  # The native <video> element handles B-frames correctly (unlike MSE's
  # SourceBuffer), and the browser plays HEVC natively on macOS via
  # VideoToolbox.  -c:v copy runs at near network speed — no re-encode.
  REMUX_COMPATIBLE_CODECS = %w[h264 hevc h265].freeze

  def remux_direct_playable?(video_stream)
    codec = video_stream[:codec_name].to_s.downcase
    REMUX_COMPATIBLE_CODECS.include?(codec)
  end

  def remux_direct_url(input_url)
    "/transcode?url=#{CGI.escape(input_url)}&remux=1"
  end
end
