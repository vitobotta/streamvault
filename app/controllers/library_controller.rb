# frozen_string_literal: true

class LibraryController < ApplicationController
  before_action :authenticate_user!
  before_action :set_entry, only: [:update, :destroy]

  def index
    @page = (params[:page] || 1).to_i.clamp(1, Float::INFINITY)
    @per_page = (params[:per_page] || 25).to_i.clamp(1, 100)

    entries = policy_scope(LibraryEntry).includes(:user)
    entries = entries.by_type(params[:type]) if params[:type].present?
    entries = entries.by_status(params[:status]) if params[:status].present?
    entries = entries.recently_added

    @total = entries.count
    @total_pages = (@total.to_f / @per_page).ceil
    @page = @page.clamp(1, [@total_pages, 1].max)
    @entries = entries.offset((@page - 1) * @per_page).limit(@per_page)

    # Progress map for cards
    imdb_ids = @entries.map(&:imdb_id)
    show_ids = @entries.select(&:show?).map(&:imdb_id)
    progress_rows = current_user.watch_history_entries
      .where("imdb_id IN (:ids) OR show_imdb_id IN (:ids)", ids: imdb_ids + show_ids)
      .group(:show_imdb_id, :imdb_id)
      .select("COALESCE(show_imdb_id, imdb_id) as key, MAX(progress_percentage) as max_progress")
    @progress_map = progress_rows.index_by(&:key)
  end

  def create
    @entry = current_user.library_entries.build(entry_params)

    if @entry.save
      current_user.wishlist_entries.find_by(imdb_id: @entry.imdb_id)&.destroy
      respond_to do |format|
        format.html { redirect_to library_index_path, notice: "#{@entry.title} added to library." }
        format.json { render json: { ok: true, kind: "library", destroy_url: library_path(@entry), notice: "#{@entry.title} added to library." } }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: library_index_path, alert: @entry.errors.full_messages.join(", ") }
        format.json { render json: { ok: false, error: @entry.errors.full_messages.join(", ") }, status: :unprocessable_content }
      end
    end
  end

  def update
    if @entry.update(entry_params)
      redirect_to library_index_path, notice: "#{@entry.title} updated."
    else
      redirect_to library_index_path, alert: @entry.errors.full_messages.join(", ")
    end
  end

  def destroy
    title = @entry.title
    @entry.destroy
    respond_to do |format|
      format.html { redirect_to library_index_path, notice: "#{title} removed from library." }
      format.json { render json: { ok: true, kind: "library" } }
    end
  end

  private

  def set_entry
    @entry = current_user.library_entries.find(params[:id])
  end

  def entry_params
    params.require(:library_entry).permit(:content_type, :imdb_id, :title, :poster_url, :year, :watch_status, :current_season, :current_episode)
  end
end
