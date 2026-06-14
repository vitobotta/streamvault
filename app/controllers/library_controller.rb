# frozen_string_literal: true

class LibraryController < ApplicationController
  before_action :authenticate_user!
  before_action :set_entry, only: [:update, :destroy]

  def index
    @entries = policy_scope(LibraryEntry).includes(:user)
    @entries = @entries.by_type(params[:type]) if params[:type].present?
    @entries = @entries.by_status(params[:status]) if params[:status].present?
    @entries = @entries.recently_added
  end

  def create
    @entry = current_user.library_entries.build(entry_params)

    if @entry.save
      # Remove from wishlist if exists
      current_user.wishlist_entries.find_by(imdb_id: @entry.imdb_id)&.destroy
      redirect_to library_index_path, notice: "#{@entry.title} added to library."
    else
      redirect_back fallback_location: library_index_path, alert: @entry.errors.full_messages.join(", ")
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
    redirect_to library_index_path, notice: "#{title} removed from library."
  end

  private

  def set_entry
    @entry = current_user.library_entries.find(params[:id])
  end

  def entry_params
    params.require(:library_entry).permit(:content_type, :imdb_id, :title, :poster_url, :year, :watch_status, :current_season, :current_episode)
  end
end
