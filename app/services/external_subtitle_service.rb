# frozen_string_literal: true

require "base64"
require "digest"

class ExternalSubtitleService
  STREAM_PREFIX = "external:"
  WINDOW_LOOK_BEHIND_SECONDS = 5
  CACHE_TTL = 12.hours

  def self.search(imdb_id:, type:, season: nil, episode: nil, title: nil, filename: nil, preferred_languages: [], default_language: nil)
    subdl_provider.search(
      imdb_id: imdb_id,
      type: type,
      season: season,
      episode: episode,
      title: title,
      filename: filename,
      preferred_languages: preferred_languages,
      default_language: default_language
    )
  end

  def self.external_stream?(value)
    value.to_s.start_with?(STREAM_PREFIX)
  end

  def self.stream_id(provider, payload)
    encoded = Base64.urlsafe_encode64(payload.to_s, padding: false)
    "#{STREAM_PREFIX}#{provider}:#{encoded}"
  end

  def self.extract_subtitles(stream_id, start_seconds: 0, duration_seconds: TranscodeService::SUBTITLE_EXTRACTION_WINDOW_SECONDS)
    provider, payload = parse_stream_id(stream_id)
    return subtitle_result(:invalid_stream, diagnostic: "invalid external subtitle stream") unless provider && payload
    return subtitle_result(:unsupported_track, diagnostic: "external subtitle provider is not available") unless provider == "subdl"

    cues_result = cached_cues(provider, payload)
    return cues_result if cues_result.is_a?(TranscodeService::SubtitleExtractionResult)

    windowed_cues = cues_in_window(cues_result, start_seconds, duration_seconds)
    return subtitle_result(:empty_window, source: provider) if windowed_cues.empty?

    subtitle_result(
      :ok,
      vtt: webvtt_from_cues(windowed_cues),
      cue_count: windowed_cues.length,
      source: provider
    )
  rescue StandardError => e
    Rails.logger.error("[ExternalSubtitles] extraction failed: #{e.class.name}")
    subtitle_result(:failed, diagnostic: e.class.name)
  end

  def self.subdl_provider
    @subdl_provider ||= SubdlSubtitleProvider.new
  end

  def self.subdl_provider=(provider)
    @subdl_provider = provider
  end

  def self.parse_stream_id(stream_id)
    prefix, provider, encoded = stream_id.to_s.split(":", 3)
    return nil unless "#{prefix}:" == STREAM_PREFIX && provider.present? && encoded.present?

    padded = encoded + ("=" * ((4 - encoded.length % 4) % 4))
    [ provider, Base64.urlsafe_decode64(padded) ]
  rescue ArgumentError
    nil
  end
  private_class_method :parse_stream_id

  def self.cached_cues(provider, payload)
    cache_key = "external_subtitles/#{provider}/#{Digest::SHA256.hexdigest(payload)}"
    cached = Rails.cache.read(cache_key)
    return cached if cached

    download_result = subdl_provider.download(payload)
    return subtitle_result(:failed, source: provider, diagnostic: download_result.error_message) if download_result.failure?

    cues = parse_subtitle_file(download_result.data)
    return subtitle_result(:failed, source: provider, diagnostic: "external subtitle file had no readable cues") if cues.empty?

    Rails.cache.write(cache_key, cues, expires_in: CACHE_TTL)
    cues
  end
  private_class_method :cached_cues

  def self.cues_in_window(cues, start_seconds, duration_seconds)
    start_at = normalized_start_seconds(start_seconds)
    duration = normalized_duration_seconds(duration_seconds)
    window_start = [ start_at - WINDOW_LOOK_BEHIND_SECONDS, 0 ].max
    window_end = start_at + duration

    cues.select { |cue| cue[:end] >= window_start && cue[:start] <= window_end }
  end
  private_class_method :cues_in_window

  def self.parse_subtitle_file(text)
    normalized = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    if normalized.lstrip.start_with?("WEBVTT")
      parse_webvtt(normalized)
    else
      parse_srt(normalized)
    end
  end
  private_class_method :parse_subtitle_file

  def self.parse_srt(text)
    text
      .gsub(/\r\n?/, "\n")
      .split(/\n{2,}/)
      .filter_map { |block| parse_timed_block(block.lines.map(&:strip)) }
  end
  private_class_method :parse_srt

  def self.parse_webvtt(text)
    text
      .gsub(/\r\n?/, "\n")
      .sub(/\AWEBVTT[^\n]*\n+/, "")
      .split(/\n{2,}/)
      .filter_map { |block| parse_timed_block(block.lines.map(&:strip)) }
  end
  private_class_method :parse_webvtt

  def self.parse_timed_block(lines)
    lines = lines.reject(&:blank?)
    return nil if lines.empty?

    lines.shift if lines.first.match?(/\A\d+\z/) && lines.second&.include?("-->")
    timing_index = lines.index { |line| line.include?("-->") }
    return nil unless timing_index

    start_text, end_text = lines[timing_index].split("-->", 2).map(&:strip)
    start_seconds = parse_timestamp(start_text)
    end_seconds = parse_timestamp(end_text.to_s.split(/\s+/).first)
    return nil unless start_seconds && end_seconds && end_seconds > start_seconds

    cue_text = lines[(timing_index + 1)..].to_a
      .map { |line| clean_cue_text(line) }
      .reject(&:blank?)
      .join("\n")
    return nil if cue_text.blank?

    { start: start_seconds, end: end_seconds, text: cue_text }
  end
  private_class_method :parse_timed_block

  def self.parse_timestamp(value)
    text = value.to_s.tr(",", ".")
    parts = text.split(":")
    return nil unless parts.length.between?(2, 3)

    seconds = Float(parts.pop, exception: false)
    minutes = Integer(parts.pop, exception: false)
    hours = parts.empty? ? 0 : Integer(parts.pop, exception: false)
    return nil unless seconds&.finite? && minutes && hours

    (hours * 3600) + (minutes * 60) + seconds
  end
  private_class_method :parse_timestamp

  def self.clean_cue_text(text)
    text
      .to_s
      .gsub(/\{[^}]*\}/, "")
      .gsub(/<[^>]+>/, "")
      .strip
  end
  private_class_method :clean_cue_text

  def self.webvtt_from_cues(cues)
    body = cues
      .sort_by { |cue| cue[:start] }
      .map do |cue|
        "#{format_timestamp(cue[:start])} --> #{format_timestamp(cue[:end])}\n#{cue[:text]}"
      end
      .join("\n\n")
    "WEBVTT\n\n#{body}\n"
  end
  private_class_method :webvtt_from_cues

  def self.format_timestamp(seconds)
    milliseconds = (seconds.to_f * 1000).round
    hours = milliseconds / 3_600_000
    milliseconds %= 3_600_000
    minutes = milliseconds / 60_000
    milliseconds %= 60_000
    whole_seconds = milliseconds / 1000
    milliseconds %= 1000

    format("%02d:%02d:%02d.%03d", hours, minutes, whole_seconds, milliseconds)
  end
  private_class_method :format_timestamp

  def self.normalized_start_seconds(value)
    seconds = value.to_f
    seconds.finite? && seconds.positive? ? seconds : 0
  end
  private_class_method :normalized_start_seconds

  def self.normalized_duration_seconds(value)
    seconds = value.to_i
    return TranscodeService::SUBTITLE_EXTRACTION_WINDOW_SECONDS unless seconds.positive?

    seconds.clamp(
      TranscodeService::MIN_SUBTITLE_EXTRACTION_WINDOW_SECONDS,
      TranscodeService::MAX_SUBTITLE_EXTRACTION_WINDOW_SECONDS
    )
  end
  private_class_method :normalized_duration_seconds

  def self.subtitle_result(status, vtt: "", cue_count: 0, source: nil, diagnostic: nil)
    TranscodeService::SubtitleExtractionResult.new(
      status: status,
      vtt: vtt.to_s,
      cue_count: cue_count.to_i,
      source: source,
      diagnostic: diagnostic
    )
  end
  private_class_method :subtitle_result
end
