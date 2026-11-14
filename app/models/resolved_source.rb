# frozen_string_literal: true

require "ipaddr"
require "socket"
require "uri"

class ResolvedSource
  PURPOSE = "resolved-source"
  TOKEN_TTL = 12.hours
  REALDEBRID_HOSTS = %w[real-debrid.com download.real-debrid.com streaming.real-debrid.com].freeze
  TORBOX_HOSTS = %w[torbox.app].freeze
  PRIVATE_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ::1/128 fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  class Invalid < StandardError; end

  attr_reader :url, :filename, :service

  def initialize(url:, filename: nil, service: nil)
    @url = url.to_s
    @filename = filename.to_s.presence || inferred_filename
    @service = (service.presence || inferred_service).to_s.presence
    raise Invalid, "untrusted stream host" unless trusted_host?

    freeze
  end

  def self.issue(user:, url:, filename: nil, service: nil)
    source = new(url: url, filename: filename, service: service)
    ApplicationToken.issue(
      { "user_id" => user.id, "url" => source.url, "filename" => source.filename, "service" => source.service },
      purpose: PURPOSE,
      expires_in: TOKEN_TTL
    )
  end

  def self.resolve(token:, user:, verify_dns: true)
    payload = ApplicationToken.verify(token, purpose: PURPOSE)
    raise Invalid, "source belongs to another user" unless payload.fetch("user_id").to_i == user.id

    source = new(url: payload.fetch("url"), filename: payload["filename"], service: payload["service"])
    raise Invalid, "stream host did not resolve publicly" if verify_dns && !source.public_address?

    source
  rescue ApplicationToken::Invalid, KeyError
    raise Invalid, "invalid or expired source"
  end

  # Only RealDebrid download hosts need the account bearer token.  Sending a
  # RealDebrid key to a TorBox or AIOStreams host would leak it.
  def request_headers(user)
    return {} unless service == "realdebrid"

    key = user.respond_to?(:effective_realdebrid_api_key) ? user.effective_realdebrid_api_key : user.realdebrid_api_key
    return {} if key.blank?

    { "Authorization" => "Bearer #{key}" }
  end

  def public_address?
    addresses = Addrinfo.getaddrinfo(uri.host, nil, :UNSPEC, :STREAM).map(&:ip_address).uniq
    addresses.any? && addresses.none? { |address| private_address?(address) }
  rescue SocketError
    false
  end

  def to_h
    { url: url, filename: filename, service: service }
  end

  private

  def uri
    @uri ||= URI.parse(url)
  rescue URI::InvalidURIError
    raise Invalid, "invalid stream URL"
  end

  def trusted_host?
    return false unless uri.is_a?(URI::HTTPS) && uri.host.present?

    host = uri.host.downcase
    return true if REALDEBRID_HOSTS.any? { |allowed| host_matches?(host, allowed) }
    return true if TORBOX_HOSTS.any? { |allowed| host_matches?(host, allowed) }

    # A provider/addon host is optional configuration; a failure to read it
    # must not reject RealDebrid or TorBox URLs.
    StreamProvider.source_hosts.any? { |allowed| host_matches?(host, allowed.to_s.downcase) }
  rescue StandardError
    false
  end

  def host_matches?(host, allowed)
    allowed.present? && (host == allowed || host.end_with?(".#{allowed}"))
  end

  def inferred_service
    host = uri.host.to_s.downcase
    return "realdebrid" if REALDEBRID_HOSTS.any? { |allowed| host_matches?(host, allowed) }
    return "torbox" if TORBOX_HOSTS.any? { |allowed| host_matches?(host, allowed) }

    nil
  end

  def inferred_filename
    File.basename(uri.path.to_s).presence || "stream"
  end

  def private_address?(address)
    ip = IPAddr.new(address)
    PRIVATE_NETWORKS.any? { |network| network.include?(ip) }
  rescue IPAddr::InvalidAddressError
    true
  end
end
