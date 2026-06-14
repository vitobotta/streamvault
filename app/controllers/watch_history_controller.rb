# frozen_string_literal: true

class WatchHistoryController < ApplicationController
  before_action :authenticate_user!

  def index
    @entries = current_user.watch_history_entries.recently_watched.limit(100)
  end

  def clear_all
    current_user.watch_history_entries.destroy_all
    current_user.episode_progresses.destroy_all
    redirect_to watch_history_index_path, notice: "Watch history cleared."
  end
end
