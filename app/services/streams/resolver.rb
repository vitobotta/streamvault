# frozen_string_literal: true

module Streams
  class Resolver
    MAX_ATTEMPTS = 50
    BATCH_SIZE = 10
    RESOLVE_RETRIES = 1
    MAX_TRANSCODE_SOURCE_BITRATE_BPS = 16_000_000
    HEAVY_VIDEO_CODECS = %w[hevc h265 av1 vp9].freeze
    BLOCKED_PATTERNS = /downloading|infringing|failed|removed|blocked/i

    def initialize(user, available_streams: AvailableStreamsService.new(user), logger: Rails.logger)
      @user = user
      @available_streams = available_streams
      @logger = logger
    end

    def start(content_ref)
      return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

      streams_result = available(content_ref)
      return streams_result if streams_result.failure?

      resolved = resolve_first_valid(candidates(streams_result.data))
      resolved ? success(resolved, content_ref) : ServiceResult.failure("No instant streams available. All streams are blocked or unavailable.")
    end

    def resolve(candidate, content_ref:, duration: nil)
      return ServiceResult.failure("RealDebrid API key not configured") unless @user.has_realdebrid_key?

      selected = StreamCandidate.from(candidate)
      resolved = playback_safe_alternative(selected, content_ref, duration) if oversized_transcode_source?(selected, duration)
      resolved ||= resolve_candidate(selected)
      resolved ||= fallback(selected, content_ref)
      resolved ? success(resolved, content_ref) : ServiceResult.failure("Could not resolve the selected stream. It may be blocked or unavailable.")
    end

    private

    def available(content_ref)
      @available_streams.call(
        imdb_id: content_ref.imdb_id,
        type: content_ref.type,
        season: content_ref.season,
        episode: content_ref.episode
      )
    end

    def candidates(streams)
      normalized = streams.filter_map do |stream|
        candidate = StreamCandidate.from(stream)
        candidate if candidate.resolve_url.present?
      end
      interleave_providers(normalized).first(MAX_ATTEMPTS)
    end

    def interleave_providers(candidates)
      groups = candidates.group_by { |candidate| candidate.provider.to_s }.values
      selected = []
      index = 0

      while selected.length < MAX_ATTEMPTS
        added = false
        groups.each do |group|
          candidate = group[index]
          next unless candidate

          selected << candidate
          added = true
          break if selected.length >= MAX_ATTEMPTS
        end
        break unless added

        index += 1
      end

      selected
    end

    def playback_safe_alternative(selected, content_ref, duration)
      result = available(content_ref)
      return if result.failure?

      alternatives = candidates(result.data)
        .reject { |candidate| candidate.resolve_url == selected.resolve_url }
        .select { |candidate| playback_safe?(candidate, duration) }
        .sort_by { |candidate| playback_sort_key(candidate) }
      resolve_first_valid(alternatives)
    end

    def fallback(selected, content_ref)
      result = available(content_ref)
      return if result.failure?

      resolve_first_valid(candidates(result.data).reject { |candidate| candidate.resolve_url == selected.resolve_url })
    end

    def oversized_transcode_source?(candidate, duration)
      return false unless HEAVY_VIDEO_CODECS.include?(candidate.video_codec.to_s.downcase)

      bitrate = estimated_bitrate(candidate.raw_size, duration)
      bitrate && bitrate > MAX_TRANSCODE_SOURCE_BITRATE_BPS
    end

    def playback_safe?(candidate, duration)
      bitrate = estimated_bitrate(candidate.raw_size, duration)
      return bitrate <= MAX_TRANSCODE_SOURCE_BITRATE_BPS if bitrate

      candidate.compatibility_score >= StreamCompatibility::COMPATIBILITY_SCORES[:stream_copy]
    end

    def playback_sort_key(candidate)
      [
        candidate.language_score,
        -candidate.compatibility_score,
        Ranker::QUALITY_ORDER.fetch(candidate.quality.to_s, Ranker::QUALITY_ORDER["Unknown"]),
        -candidate.raw_size
      ]
    end

    def estimated_bitrate(raw_size, duration)
      bytes = Float(raw_size, exception: false)
      seconds = Float(duration, exception: false)
      return unless bytes&.positive? && seconds&.between?(60, 24.hours.to_i)

      bytes * 8 / seconds
    end

    def resolve_first_valid(streams)
      streams.group_by(&:language_score).sort_by(&:first).each do |_language_score, language_group|
        language_group.each_slice(BATCH_SIZE) do |batch|
          winner = resolve_batch(batch)
          return winner if winner
        end
      end
      nil
    end

    def resolve_batch(streams)
      results = Queue.new
      threads = streams.map do |candidate|
        Thread.new do
          results << resolve_candidate(candidate)
        rescue StandardError => e
          @logger.warn("[Streams::Resolver] candidate failed: #{e.class}")
          results << nil
        end
      end
      streams.length.times do
        resolved = results.pop
        return resolved if resolved
      end
      nil
    ensure
      threads&.each(&:kill)
      threads&.each { |thread| thread.join(0.1) }
    end

    def resolve_candidate(candidate)
      source = resolve_url(candidate.resolve_url)
      source && { source: source, stream: candidate }
    end

    def resolve_url(resolve_url)
      return unless allowed_resolve_url?(resolve_url)

      response = with_retries { connection_for(resolve_url).get(resolve_url) }
      return unless response

      source_url = if [ 301, 302, 303, 307, 308 ].include?(response.status)
        response.headers["location"]
      elsif [ 200, 206 ].include?(response.status)
        resolve_url
      end
      return if source_url.blank? || source_url.match?(BLOCKED_PATTERNS)

      ResolvedSource.new(url: source_url)
    rescue ResolvedSource::Invalid
      nil
    end

    def success(resolved, content_ref)
      candidate = resolved.fetch(:stream)
      source = resolved.fetch(:source)
      filename = candidate.filename.presence || source.filename
      source = ResolvedSource.new(url: source.url, filename: filename)
      ServiceResult.success({
        source: source,
        stream: candidate.merge(filename: filename),
        direct_play_hint: candidate.compatibility_score == StreamCompatibility::COMPATIBILITY_SCORES[:direct_play],
        content_ref: content_ref
      })
    end

    def with_retries
      attempts = 0
      begin
        attempts += 1
        yield
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed
        retry if attempts <= RESOLVE_RETRIES
        nil
      end
    end

    def allowed_resolve_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTP) && allowed_origins.any? do |origin|
        uri.scheme == origin.scheme && uri.host == origin.host && uri.port == origin.port
      end
    rescue URI::InvalidURIError
      false
    end

    def allowed_origins
      @allowed_origins ||= StreamProvider.resolve_base_urls.filter_map do |url|
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end.uniq { |uri| [ uri.scheme, uri.host, uri.port ] }
    end

    def connection_for(resolve_url)
      return direct_connection if CometService.comet_url.present? && resolve_url.start_with?(CometService.comet_url)

      @proxy_connection ||= Faraday.new do |faraday|
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = 15
        faraday.options.open_timeout = 5
        faraday.proxy = ENV["TORRENTIO_PROXY"] if ENV["TORRENTIO_PROXY"].present?
      end
    end

    def direct_connection
      @direct_connection ||= Faraday.new do |faraday|
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = 15
        faraday.options.open_timeout = 5
      end
    end
  end
end
