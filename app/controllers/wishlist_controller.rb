# frozen_string_literal: true

class WishlistController < ApplicationController
  before_action :authenticate_user!
  before_action :set_entry, only: [ :destroy, :move_to_library ]

  def index
    @page = (params[:page] || 1).to_i.clamp(1, Float::INFINITY)
    @per_page = (params[:per_page] || 25).to_i.clamp(1, 100)

    entries = policy_scope(WishlistEntry)
    entries = entries.by_type(params[:type]) if params[:type].present?
    entries = entries.recently_added

    @total = entries.count
    @total_pages = (@total.to_f / @per_page).ceil
    @page = @page.clamp(1, [ @total_pages, 1 ].max)
    @entries = entries.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def create
    @entry = current_user.wishlist_entries.build(entry_params)

    if @entry.save
      respond_to do |format|
        format.html { redirect_to wishlist_index_path, notice: "#{@entry.title} added to wishlist." }
        format.json { render json: { ok: true, kind: "wishlist", destroy_url: wishlist_path(@entry), notice: "#{@entry.title} added to wishlist." } }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: wishlist_index_path, alert: @entry.errors.full_messages.join(", ") }
        format.json { render json: { ok: false, error: @entry.errors.full_messages.join(", ") }, status: :unprocessable_content }
      end
    end
  end

  def destroy
    title = @entry.title
    @entry.destroy
    respond_to do |format|
      format.html { redirect_to wishlist_index_path, notice: "#{title} removed from wishlist." }
      format.json { render json: { ok: true, kind: "wishlist" } }
    end
  end

  def move_to_library
    result = CollectionMembershipService.move_to_library(
      user: current_user,
      wishlist_entry: @entry
    )

    if result.success?
      redirect_to library_index_path, notice: "#{result.data.title} moved to library."
    else
      redirect_back fallback_location: wishlist_index_path, alert: result.error_message
    end
  end

  private

  def set_entry
    @entry = current_user.wishlist_entries.find(params[:id])
  end

  def entry_params
    params.require(:wishlist_entry).permit(:content_type, :imdb_id, :title, :poster_url, :year)
  end
end
