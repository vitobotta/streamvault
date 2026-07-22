# frozen_string_literal: true

class WatchHistoryController < ApplicationController
  before_action :authenticate_user!

  def index
    @page = (params[:page] || 1).to_i.clamp(1, Float::INFINITY)
    @per_page = (params[:per_page] || 25).to_i.clamp(1, 100)

    # Use policy_scope for consistency with library/wishlist/home — if a
    # future policy adds a scope condition (e.g. hide soft-deleted), this
    # controller will honour it rather than silently bypassing it.
    entries = policy_scope(WatchHistoryEntry).recently_watched

    @total = entries.count
    @total_pages = (@total.to_f / @per_page).ceil
    @page = @page.clamp(1, [ @total_pages, 1 ].max)
    @entries = entries.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def destroy
    entry = current_user.watch_history_entries.find(params[:id])

    result = WatchHistoryCleanupService.remove(user: current_user, entry: entry)
    if result.failure?
      redirect_back fallback_location: watch_history_index_path, status: :see_other, alert: result.error_message
      return
    end

    redirect_back fallback_location: watch_history_index_path, status: :see_other, notice: "Removed from history."
  end

  def clear_all
    result = WatchHistoryCleanupService.clear(user: current_user)
    if result.failure?
      redirect_to watch_history_index_path, alert: result.error_message
      return
    end
    redirect_to watch_history_index_path, notice: "Watch history cleared."
  end
end
