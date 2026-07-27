# frozen_string_literal: true

class SearchController < ApplicationController
  before_action :authenticate_user!

  def index
    @query = params[:q]

    if @query.present?
      catalog = Catalog::CinemetaClient.new
      result = catalog.search(@query)
      all_results = result.success? ? result.data : []
      @error = result.failure? ? result.error_message : nil

      @pagination = PageSlice.from_array(
        all_results,
        page: params.fetch(:page, 1),
        per_page: params.fetch(:per_page, 25),
        max_per_page: 200
      )
      @results = @pagination.items
    else
      @pagination = PageSlice.from_array([], page: 1, per_page: 25, max_per_page: 200)
      @results = @pagination.items
    end
  end
end
