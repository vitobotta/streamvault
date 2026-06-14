# frozen_string_literal: true

class ContentController < ApplicationController
  before_action :authenticate_user!

  def show
    @imdb_id = params[:imdb_id]
    @type = params[:type]

    torrentio = TorrentioService.new

    # Fetch metadata
    meta_result = torrentio.metadata(@imdb_id, @type)
    @metadata = meta_result.success? ? meta_result.data : nil

    # Fetch streams
    streams_result = torrentio.streams(@imdb_id, @type, season: params[:season]&.to_i, episode: params[:episode]&.to_i)
    @streams = streams_result.success? ? streams_result.data : []

    # Check library/wishlist status
    @in_library = current_user.library_entries.exists?(imdb_id: @imdb_id)
    @in_wishlist = current_user.wishlist_entries.exists?(imdb_id: @imdb_id)
    @library_entry = current_user.library_entries.find_by(imdb_id: @imdb_id)
  end
end
