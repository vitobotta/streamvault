# frozen_string_literal: true

# Factory that returns the configured stream provider(s).
#
# STREAM_PROVIDER env var:
#   "comet"     → Comet primary, Torrentio fallback
#   "torrentio" → Torrentio only (default)
#   "auto"      → configured Comet followed by Torrentio
#   "comet"     → configured Comet followed by Torrentio
#
# Each provider implements:
#   streams(imdb_id, type, season:, episode:, title:, preferred_languages:, default_language:)
#     → ServiceResult<Array<StreamCandidate>>
#   resolve_base_urls → Array<String> (for resolver origin validation)
module StreamProvider
  module_function

  # Returns an ordered array of provider instances configured for the user.
  # The first provider is primary; subsequent ones are fallbacks used when
  # the primary returns no streams or fails to connect.
  def providers(rd_api_key:)
    torrentio = Streams::TorrentioProvider.new(rd_api_key: rd_api_key)
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase
    return [ torrentio ] unless %w[comet auto].include?(setting)

    [ (CometService.new(rd_api_key: rd_api_key) if CometService.comet_url.present?), torrentio ].compact
  end

  # All origins from which the resolver may follow a provider URL.
  def resolve_base_urls
    urls = [ Streams::TorrentioProvider::BASE_URL, "https://torrentio.strem.fun" ]
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase
    urls.unshift(CometService.comet_url) if %w[comet auto].include?(setting) && CometService.comet_url.present?
    urls.uniq
  end
end
