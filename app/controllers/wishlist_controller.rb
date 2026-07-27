# frozen_string_literal: true

class WishlistController < ApplicationController
  before_action :authenticate_user!

  def index
    entries = current_user.collection_entries.wishlist
    entries = entries.by_type(params[:type]) if params[:type].present?
    entries = entries.recently_added
    @pagination = PageSlice.from_relation(
      entries,
      page: params.fetch(:page, 1),
      per_page: params.fetch(:per_page, 25)
    )
    @entries = @pagination.items
  end
end
