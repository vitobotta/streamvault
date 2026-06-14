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

    # For movies, fetch streams directly. For shows, streams are loaded per-episode.
    if @type != "show"
      content_title = @metadata&.dig(:title)
      streams_result = torrentio.streams(@imdb_id, @type, title: content_title)
      @streams = streams_result.success? ? streams_result.data : []
    end

    # Check library/wishlist status
    @in_library = current_user.library_entries.exists?(imdb_id: @imdb_id)
    @in_wishlist = current_user.wishlist_entries.exists?(imdb_id: @imdb_id)
    @library_entry = current_user.library_entries.find_by(imdb_id: @imdb_id)

    # For shows, get user's episode progress and selected season
    if @type == "show"
      @episode_progress = current_user.episode_progresses.for_show(@imdb_id).index_by { |ep| [ep.season_number, ep.episode_number] }
      @selected_season = params[:season]&.to_i || 1
    end
  end

  # GET /content/:type/:imdb_id/episode_streams?season=N&episode=N
  def episode_streams
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]&.to_i
    @episode = params[:episode]&.to_i

    torrentio = TorrentioService.new

    # Get show title and episode title for stream filtering
    meta = torrentio.metadata(@imdb_id, @type)
    @show_title = meta.success? ? meta.data[:title] : @imdb_id
    @episode_title = ""
    if meta.success? && meta.data[:episodes]
      ep = meta.data[:episodes].find { |e| e[:season] == @season && e[:episode] == @episode }
      @episode_title = ep&.dig(:title).to_s
    end

    # Build combined title for filtering
    filter_title = [@show_title, @episode_title].compact_blank.join(" ")

    streams_result = torrentio.streams(@imdb_id, "show", season: @season, episode: @episode, title: filter_title)
    @streams = streams_result.success? ? streams_result.data : []

    render layout: false
  end
end
