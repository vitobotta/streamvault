# frozen_string_literal: true

class SearchController < ApplicationController
  before_action :authenticate_user!

  def index
    if params[:q].present?
      @torrentio = TorrentioService.new
      result = @torrentio.search(params[:q])
      @results = result.success? ? result.data : []
      @error = result.failure? ? result.error_message : nil
    else
      @results = []
    end
  end
end
