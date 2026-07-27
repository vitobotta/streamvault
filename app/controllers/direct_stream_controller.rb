# frozen_string_literal: true

class DirectStreamController < ApplicationController
  include ActionController::Live
  include ResolvedSourceAccess

  before_action :authenticate_user!

  MAX_REDIRECTS = 5

  # GET /direct_stream?source=... — transparent HTTP proxy for direct play.
  # Forwards the protected RealDebrid source with auth headers and Range
  # passthrough, so the browser's <video> element downloads at network speed
  # and seeks via Range requests — no ffmpeg involved.
  def show
    range = request.headers["HTTP_RANGE"]
    playback_id = normalized_playback_id(params[:playback_id])
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    written_bytes = 0
    expected_bytes = nil
    upstream_status = nil
    outcome = "complete"
    begin
      source = resolved_source

    response.headers["Cache-Control"] = "no-cache"
    response.headers["Accept-Ranges"] = "bytes"
    response.headers["X-Accel-Buffering"] = "no"

    uri = URI.parse(source.url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.read_timeout = 60
    http.open_timeout = 10

    request_headers = source_headers
    request_headers["Range"] = range if range

      http.request_get(uri.request_uri, request_headers) do |upstream|
        upstream_status = upstream.code.to_i
        expected_bytes = Integer(upstream["Content-Length"], exception: false)
        response.status = upstream_status
        pass_through_header(upstream, "Content-Type")
        pass_through_header(upstream, "Content-Length")
        pass_through_header(upstream, "Content-Range")

        upstream.read_body do |chunk|
          response.stream.write(chunk)
          written_bytes += chunk.bytesize
        end
      end
      if expected_bytes && written_bytes != expected_bytes
        outcome = "truncated"
        Rails.logger.warn(
          "[DirectStream] playback_id=#{playback_id} truncated expected_bytes=#{expected_bytes} " \
          "written_bytes=#{written_bytes}"
        )
      end
    rescue ResolvedSource::Invalid
      outcome = "invalid_source"
      response.status = :bad_request unless response.committed?
    rescue ActionController::Live::ClientDisconnected => e
      outcome = "client_disconnected"
      Rails.logger.info("[DirectStream] playback_id=#{playback_id} client_disconnect=#{e.class}")
    rescue Net::ReadTimeout, Net::OpenTimeout, Net::HTTPBadResponse, OpenSSL::SSL::SSLError,
      SocketError, EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError => e
      outcome = "upstream_error"
      Rails.logger.warn("[DirectStream] playback_id=#{playback_id} upstream_error=#{e.class}")
      response.status = :bad_gateway unless response.committed?
    ensure
      response.stream.close
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      Rails.logger.info(
        "[DirectStream] playback_id=#{playback_id} range=#{normalized_range(range)} " \
        "upstream_status=#{upstream_status || 'none'} expected_bytes=#{expected_bytes || 'unknown'} " \
        "written_bytes=#{written_bytes} outcome=#{outcome} elapsed=#{elapsed.round(2)}s"
      )
    end
  end

  private

  def normalized_playback_id(value)
    sanitized = value.to_s.gsub(/[^a-zA-Z0-9_-]/, "").first(80)
    sanitized.presence || "unknown"
  end

  def normalized_range(value)
    range = value.to_s
    range.match?(/\Abytes=\d*-\d*\z/) ? range : "none"
  end


  def pass_through_header(upstream, name)
    value = upstream[name]
    response.headers[name] = value if value.present?
  end
end
