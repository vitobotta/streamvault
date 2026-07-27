# frozen_string_literal: true

module Streams
  class ReleaseParser
    include StreamCompatibility

    LANGUAGE_PATTERNS = {
      "ENG" => /\b(ENG|ENGLISH|EN)\b/i,
      "FRENCH" => /\b(FRENCH|FR|VFF|VFQ|TRUEFRENCH)\b/i,
      "GERMAN" => /\b(GERMAN|GER|DE)\b/i,
      "SPANISH" => /\b(SPANISH|SPA|ES|CASTELLANO)\b/i,
      "ITALIAN" => /\b(ITALIAN|ITA|IT)\b/i,
      "JAPANESE" => /\b(JAPANESE|JAP|JA)\b/i,
      "KOREAN" => /\b(KOREAN|KOR|KO)\b/i,
      "CHINESE" => /\b(CHINESE|CHI|ZH)\b/i,
      "HINDI" => /\b(HINDI|HIN|HI)\b/i,
      "ARABIC" => /\b(ARABIC|ARA|AR)\b/i,
      "PORTUGUESE" => /\b(PORTUGUESE|POR|PT|PTBR|BRAZILIAN)\b/i,
      "RUSSIAN" => /\b(RUSSIAN|RUS|RU)\b/i,
      "DUTCH" => /\b(DUTCH|DUT|NL|NLD)\b/i,
      "POLISH" => /\b(POLISH|POL|PL)\b/i,
      "TURKISH" => /\b(TURKISH|TUR|TR)\b/i,
      "SWEDISH" => /\b(SWEDISH|SWE|SV)\b/i
    }.freeze

    def analyze(title:, filename: nil)
      text = title.to_s
      video_codec = detect_video_codec(text)
      audio_codec = detect_audio_codec(text)
      container = detect_container(filename.to_s.presence || text)
      {
        quality: quality(text),
        raw_size: size_bytes(text) || 0,
        languages: languages(text),
        video_codec: video_codec,
        audio_codec: audio_codec,
        container: container,
        compatibility_score: compatibility_score(
          video_codec: video_codec,
          audio_codec: audio_codec,
          container: container
        )
      }
    end

    def languages(text)
      value = text.to_s
      return [] if value.blank?
      return LANGUAGE_PATTERNS.keys if value.match?(/\bMULTi|MULTIPLE|MULTI\b/i)

      LANGUAGE_PATTERNS.select { |_, pattern| value.match?(pattern) }.keys
    end

    def quality(text)
      case text.to_s
      when /2160p|4K/i then "4K"
      when /1080p/i then "1080p"
      when /720p/i then "720p"
      when /480p/i then "480p"
      else "Unknown"
      end
    end

    def size_bytes(text)
      match = text.to_s.match(/💾\s*([\d.]+)\s*(GB|MB|KB)/i)
      return unless match

      multiplier = { "GB" => 1_073_741_824, "MB" => 1_048_576, "KB" => 1024 }.fetch(match[2].upcase)
      (match[1].to_f * multiplier).to_i
    end

    def format_size(bytes)
      return "Unknown" unless bytes.is_a?(Numeric) && bytes.positive?
      return "#{(bytes / 1_073_741_824.0).round(1)} GB" if bytes >= 1_073_741_824
      return "#{(bytes / 1_048_576.0).round(1)} MB" if bytes >= 1_048_576

      "#{(bytes / 1024.0).round(1)} KB"
    end
  end
end
