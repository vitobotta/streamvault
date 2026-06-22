# frozen_string_literal: true

require "ipaddr"
require "socket"
require "uri"

module StreamUrlValidation
  PRIVATE_STREAM_NETWORKS = %w[
    0.0.0.0/8
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.0.0.0/24
    192.0.2.0/24
    192.168.0.0/16
    198.18.0.0/15
    198.51.100.0/24
    203.0.113.0/24
    224.0.0.0/4
    240.0.0.0/4
    ::1/128
    fc00::/7
    fe80::/10
    ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  private

  def valid_stream_url?(value)
    uri = URI.parse(value.to_s)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?
    return false if private_stream_host?(uri.host)

    true
  rescue URI::InvalidURIError
    false
  end

  def private_stream_host?(host)
    normalized_host = host.to_s.downcase
    return true if normalized_host == "localhost" || normalized_host.end_with?(".localhost")

    addresses = Addrinfo.getaddrinfo(normalized_host, nil, :UNSPEC, :STREAM).map(&:ip_address).uniq
    addresses.any? { |address| private_stream_address?(address) }
  rescue SocketError
    false
  end

  def private_stream_address?(address)
    ip = IPAddr.new(address)
    PRIVATE_STREAM_NETWORKS.any? { |network| network.include?(ip) }
  rescue IPAddr::InvalidAddressError
    true
  end
end
