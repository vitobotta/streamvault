# frozen_string_literal: true

class SearchController < ApplicationController
  before_action :authenticate_user!

  def index
    @query = params[:q]
    @page = (params[:page] || 1).to_i.clamp(1, Float::INFINITY)
    @per_page = (params[:per_page] || 25).to_i.clamp(1, 200)

    if @query.present?
      torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)
      result = torrentio.search(@query)
      all_results = result.success? ? result.data : []
      @error = result.failure? ? result.error_message : nil

      @total = all_results.length
      @total_pages = (@total.to_f / @per_page).ceil
      @page = @page.clamp(1, [@total_pages, 1].max)
      @results = all_results.slice((@page - 1) * @per_page, @per_page) || []
    else
      @results = []
      @total = 0
      @total_pages = 0
    end
  end
end
