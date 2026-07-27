# frozen_string_literal: true

module ResolvedSourceAccess
  extend ActiveSupport::Concern

  private

  def resolved_source
    @resolved_source ||= ResolvedSource.resolve(token: params[:source], user: current_user)
  end

  def source_headers
    resolved_source.request_headers(current_user)
  end
end
