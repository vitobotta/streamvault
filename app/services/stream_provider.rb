# frozen_string_literal: true

# Factory that returns the configured stream provider(s).
#
# STREAM_PROVIDER env var:
#   "comet"     → Comet primary, Torrentio fallback
#   "torrentio" → Torrentio primary (default, backward-compatible)
#   "auto"      → Comet if configured, else Torrentio; Comet first with
#                 Torrentio fallback when both are configured
#
# Each provider implements:
#   streams(imdb_id, type, season:, episode:, title:, preferred_languages:, default_language:)
#     → ServiceResult<Array<Hash>>
#   self.resolve_base_url → String (for ContentStreamingService origin validation)
module StreamProvider
  module_function

  # Returns an ordered array of provider instances configured for the user.
  # The first provider is primary; subsequent ones are fallbacks used when
  # the primary returns no streams or fails to connect.
  def providers(rd_api_key:)
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase

    case setting
    when "comet"
      [ CometService.new(rd_api_key: rd_api_key), TorrentioService.new(rd_api_key: rd_api_key) ]
    when "auto"
      list = []
      list << CometService.new(rd_api_key: rd_api_key) if CometService.comet_url.present?
      list << TorrentioService.new(rd_api_key: rd_api_key)
      list
    else
      [ TorrentioService.new(rd_api_key: rd_api_key) ]
    end
  end

  # All base URLs that resolve URLs may originate from — used by
  # ContentStreamingService for allowed_resolve_origins.
  def resolve_base_urls
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase
    urls = []

    case setting
    when "comet", "auto"
      urls << CometService.comet_url if CometService.comet_url.present?
      urls << TorrentioService::TORRENTIO_URL
      urls << "https://torrentio.strem.fun"
    else
      urls << TorrentioService::TORRENTIO_URL
      urls << "https://torrentio.strem.fun"
    end

    urls.uniq
  end
end
