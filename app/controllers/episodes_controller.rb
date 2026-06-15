# frozen_string_literal: true

class EpisodesController < ApplicationController
  before_action :authenticate_user!

  def index
    @show_imdb_id = params[:show_imdb_id]
    @season = params[:season]&.to_i || 1

    # Get progress for all episodes of this show
    @progress = current_user.episode_progresses.for_show(@show_imdb_id)

    # Get metadata for the show
    torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)
    meta_result = torrentio.metadata(@show_imdb_id, "show")
    @metadata = meta_result.success? ? meta_result.data : nil
    @total_seasons = @metadata&.dig(:total_seasons) || 1
  end
end
