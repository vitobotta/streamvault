# frozen_string_literal: true

# Factory that returns the configured stream provider(s).
#
# STREAM_PROVIDER env var:
#   "torrentio"   → Torrentio only (default)
#   "comet"       → Comet primary, Torrentio fallback
#   "aiostreams"  → AIOStreams primary, Torrentio fallback
#   "auto"        → AIOStreams (if configured), Comet (if configured),
#                   then Torrentio
#
# Every usable debrid credential is passed to Torrentio and Comet, which embed
# it in their addon URL/config: with both RealDebrid and TorBox keys the addons
# are queried once per service so the merged result has more stream diversity.
# The account's selected service comes first, so its streams win ties.
# AIOStreams is configured on its own instance, so it needs no key here.
#
# Each provider implements:
#   streams(imdb_id, type, season:, episode:, title:, preferred_languages:, default_language:)
#     → ServiceResult<Array<StreamCandidate>>
#   resolve_base_urls → Array<String> (for resolver origin validation)
module StreamProvider
  module_function

  def providers(rd_api_key: nil, torbox_api_key: nil, debrid_service: "realdebrid")
    credentials = debrid_credentials(rd_api_key, torbox_api_key, debrid_service)
    torrentio = credentials.map do |service, api_key|
      Streams::TorrentioProvider.new(api_key: api_key, debrid_service: service)
    end
    comet = credentials.filter_map { |service, api_key| comet_provider(api_key, service) }
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase

    case setting
    when "comet"
      comet + torrentio
    when "aiostreams"
      [ aiostreams_provider, *torrentio ].compact
    when "auto"
      [ aiostreams_provider, *comet, *torrentio ].compact
    else
      torrentio
    end
  end

  # One (service, key) pair per usable credential, preferred service first.  An
  # account with no key of its own still queries the addons keylessly, since the
  # addon may serve links that need no debrid account.
  def debrid_credentials(rd_api_key, torbox_api_key, debrid_service)
    preferred = debrid_service.to_s.presence || "realdebrid"
    pairs = []
    pairs << [ "realdebrid", rd_api_key ] if rd_api_key.present?
    pairs << [ "torbox", torbox_api_key ] if torbox_api_key.present?
    return [ [ preferred, nil ] ] if pairs.empty?

    pairs.sort_by { |service, _api_key| service == preferred ? 0 : 1 }
  end

  # AIOStreams instances are configured with their own debrid accounts, so a
  # shared instance can serve accounts that have no per-account key.  This is
  # only true when AIOStreams is actually selected and configured.
  def keyless_provider_available?
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase
    %w[aiostreams auto].include?(setting) && Streams::AioStreamsProvider.configured?
  end

  # All origins from which the resolver may follow a provider URL.
  def resolve_base_urls
    urls = [ Streams::TorrentioProvider::BASE_URL, "https://torrentio.strem.fun" ]
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase

    if %w[comet auto].include?(setting) && CometService.comet_url.present?
      urls.unshift(CometService.comet_url)
    end
    if %w[aiostreams auto].include?(setting) && Streams::AioStreamsProvider.configured?
      urls.unshift(Streams::AioStreamsProvider.base_url)
    end
    urls.uniq
  end

  # Hosts a provider is allowed to serve the final media from.  RealDebrid and
  # TorBox CDN hosts are recognised by ResolvedSource itself; these cover
  # addons that proxy playback (Comet/AIOStreams) plus explicit operator
  # additions.
  def source_hosts
    urls = [ Streams::AioStreamsProvider.base_url, CometService.comet_url ]
    urls.concat(ENV.fetch("STREAM_SOURCE_HOSTS", "").split(",").map(&:strip))
    urls.filter_map do |value|
      text = value.to_s.strip
      next nil if text.blank?

      URI.parse(text).host || (text unless text.include?("://") || text.include?("/"))
    rescue URI::InvalidURIError
      nil
    end.uniq
  end

  def comet_provider(api_key, service)
    return nil if CometService.comet_url.blank?

    CometService.new(api_key: api_key, debrid_service: service)
  end

  def aiostreams_provider
    return nil unless Streams::AioStreamsProvider.configured?

    Streams::AioStreamsProvider.new
  end
end
