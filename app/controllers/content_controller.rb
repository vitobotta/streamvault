# frozen_string_literal: true

class ContentController < ApplicationController
  before_action :authenticate_user!

  def show
    @imdb_id = params[:imdb_id]
    @type = params[:type]

    torrentio = TorrentioService.new

    # Fetch metadata (includes episodes for shows via Cinemeta)
    meta_result = torrentio.metadata(@imdb_id, @type)
    @metadata = meta_result.success? ? meta_result.data : nil

    # Fetch streams
    season = params[:season]&.to_i
    episode = params[:episode]&.to_i
    streams_result = torrentio.streams(@imdb_id, @type, season: season, episode: episode)
    @streams = streams_result.success? ? streams_result.data : []

    # Check library/wishlist status
    @in_library = current_user.library_entries.exists?(imdb_id: @imdb_id)
    @in_wishlist = current_user.wishlist_entries.exists?(imdb_id: @imdb_id)
    @library_entry = current_user.library_entries.find_by(imdb_id: @imdb_id)

    # For shows, get user's episode progress
    if @type == "show"
      @episode_progress = current_user.episode_progresses.for_show(@imdb_id).index_by { |ep| [ep.season_number, ep.episode_number] }
      @selected_season = season || 1
    end
  end
end
