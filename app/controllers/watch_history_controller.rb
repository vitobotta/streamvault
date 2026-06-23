# frozen_string_literal: true

class WatchHistoryController < ApplicationController
  before_action :authenticate_user!

  def index
    @page = (params[:page] || 1).to_i.clamp(1, Float::INFINITY)
    @per_page = (params[:per_page] || 25).to_i.clamp(1, 100)

    entries = current_user.watch_history_entries.recently_watched

    @total = entries.count
    @total_pages = (@total.to_f / @per_page).ceil
    @page = @page.clamp(1, [@total_pages, 1].max)
    @entries = entries.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def destroy
    entry = current_user.watch_history_entries.find(params[:id])
    entry.destroy!
    redirect_back fallback_location: watch_history_index_path, status: :see_other, notice: "Removed from history."
  end

  def clear_all
    current_user.watch_history_entries.destroy_all
    current_user.episode_progresses.destroy_all
    redirect_to watch_history_index_path, notice: "Watch history cleared."
  end
end
