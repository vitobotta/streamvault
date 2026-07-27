# frozen_string_literal: true

class WatchHistoryController < ApplicationController
  before_action :authenticate_user!

  def index
    @pagination = PageSlice.from_relation(
      current_user.playback_progresses.recently_watched,
      page: params.fetch(:page, 1),
      per_page: params.fetch(:per_page, 25)
    )
    @entries = @pagination.items
  end

  def destroy
    entry = current_user.playback_progresses.find(params[:id])

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
