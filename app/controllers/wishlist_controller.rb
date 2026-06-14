# frozen_string_literal: true

class WishlistController < ApplicationController
  before_action :authenticate_user!
  before_action :set_entry, only: [:destroy, :move_to_library]

  def index
    @entries = policy_scope(WishlistEntry).recently_added
  end

  def create
    @entry = current_user.wishlist_entries.build(entry_params)

    if @entry.save
      redirect_to wishlist_index_path, notice: "#{@entry.title} added to wishlist."
    else
      redirect_back fallback_location: wishlist_index_path, alert: @entry.errors.full_messages.join(", ")
    end
  end

  def destroy
    title = @entry.title
    @entry.destroy
    redirect_to wishlist_index_path, notice: "#{title} removed from wishlist."
  end

  def move_to_library
    library_entry = current_user.library_entries.create!(
      content_type: @entry.content_type,
      imdb_id: @entry.imdb_id,
      title: @entry.title,
      poster_url: @entry.poster_url,
      year: @entry.year
    )

    @entry.destroy
    redirect_to library_index_path, notice: "#{library_entry.title} moved to library."
  end

  private

  def set_entry
    @entry = current_user.wishlist_entries.find(params[:id])
  end

  def entry_params
    params.require(:wishlist_entry).permit(:content_type, :imdb_id, :title, :poster_url, :year)
  end
end
