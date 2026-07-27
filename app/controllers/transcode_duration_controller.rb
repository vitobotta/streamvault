# frozen_string_literal: true

# Separate controller for the duration probe endpoint.
# This MUST NOT include ActionController::Live — that module runs every
# action in a separate thread where Devise's throw(:warden) is not caught,
# causing an UncaughtThrowError when authentication fails.
class TranscodeDurationController < ApplicationController
  include ResolvedSourceAccess

  before_action :authenticate_user!

  # GET /transcode/duration?url=... — probe file duration via ffprobe
  def show
    source = resolved_source

    dur = Media::Probe.duration(source.url, headers: source_headers)
    render json: { duration: dur }
  rescue ResolvedSource::Invalid
    render json: { duration: 0 }, status: :bad_request
  end
end
