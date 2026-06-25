# frozen_string_literal: true

class ContentController < ApplicationController
  before_action :authenticate_user!

  def show
    @imdb_id = params[:imdb_id]
    @type = params[:type]

    torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)

    meta_result = torrentio.metadata(@imdb_id, @type)
    @metadata = meta_result.success? ? meta_result.data : nil

    if @type != "show"
      content_title = @metadata&.dig(:title)
      streams_result = fetch_provider_streams(@imdb_id, @type, title: content_title)
      @streams = streams_result.success? ? streams_result.data : []
      @streams_error = streams_result.failure? ? streams_result.error_message : nil
    end

    @in_library = current_user.library_entries.exists?(imdb_id: @imdb_id)
    @in_wishlist = current_user.wishlist_entries.exists?(imdb_id: @imdb_id)
    @library_entry = current_user.library_entries.find_by(imdb_id: @imdb_id)
    @wishlist_entry = current_user.wishlist_entries.find_by(imdb_id: @imdb_id)

    if @type == "show"
      @episode_progress = current_user.episode_progresses.for_show(@imdb_id).index_by { |ep| [ ep.season_number, ep.episode_number ] }
      @selected_season = params[:season]&.to_i || 1
      # Show progress = last watched episode
      @progress = current_user.watch_history_entries
        .find_by(show_imdb_id: @imdb_id, content_type: :episode)
        &.progress_percentage
    else
      # Movie progress
      @progress = current_user.watch_history_entries
        .find_by(imdb_id: @imdb_id, content_type: :movie)
        &.progress_percentage
    end
  end

  def status
    imdb_id = params[:imdb_id]
    library_entry = current_user.library_entries.find_by(imdb_id: imdb_id)
    wishlist_entry = current_user.wishlist_entries.find_by(imdb_id: imdb_id)

    render json: {
      in_library: library_entry.present?,
      in_wishlist: wishlist_entry.present?,
      library_entry_id: library_entry&.id,
      wishlist_entry_id: wishlist_entry&.id
    }
  end

  def episode_streams
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]&.to_i
    @episode = params[:episode]&.to_i

    torrentio = TorrentioService.new(rd_api_key: current_user&.realdebrid_api_key)

    meta = torrentio.metadata(@imdb_id, @type)
    @show_title = meta.success? ? meta.data[:title] : @imdb_id
    @poster_url = meta.success? ? meta.data[:poster_url] : nil
    @episode_title = ""
    @episode_duration_seconds = nil
    if meta.success? && meta.data[:episodes]
      ep = meta.data[:episodes].find { |e| e[:season] == @season && e[:episode] == @episode }
      @episode_title = ep&.dig(:title).to_s
      @episode_duration_seconds = ep&.dig(:runtime_seconds)
    end

    filter_title = "#{@show_title} #{@episode_title}"
    streams_result = fetch_provider_streams(
      @imdb_id,
      "show",
      season: @season,
      episode: @episode,
      title: filter_title
    )
    @streams = streams_result.success? ? streams_result.data : []
    @streams_error = streams_result.failure? ? streams_result.error_message : nil

    render layout: false
  end

  private

  # Fetch streams from all configured providers, merging results.
  def fetch_provider_streams(imdb_id, type, season: nil, episode: nil, title: nil)
    providers = StreamProvider.providers(rd_api_key: current_user&.realdebrid_api_key)
    all_streams = []

    providers.each do |provider|
      result = provider.streams(
        imdb_id,
        type,
        season: season,
        episode: episode,
        title: title,
        preferred_languages: current_user.preferred_stream_languages,
        default_language: current_user.default_stream_language
      )
      all_streams.concat(result.data) if result.success?
    end

    all_streams.empty? ? ServiceResult.failure("No streams available") : ServiceResult.success(all_streams)
  end
end
