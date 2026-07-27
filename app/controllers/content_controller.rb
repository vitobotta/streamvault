# frozen_string_literal: true

class ContentController < ApplicationController
  include ContentParamValidation
  before_action :authenticate_user!

  def show
    @imdb_id = params[:imdb_id]
    @type = params[:type]

    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    catalog = Catalog::CinemetaClient.new

    meta_result = catalog.metadata(@imdb_id, @type)
    @metadata = meta_result.success? ? meta_result.data : nil

    if @type != "show"
      content_title = @metadata&.dig(:title)
      streams_result = AvailableStreamsService.new(current_user).call(
        imdb_id: @imdb_id,
        type: @type,
        title: content_title
      )
      @streams = streams_result.success? ? streams_result.data : []
      @streams_error = streams_result.failure? ? streams_result.error_message : nil
    end

    @collection_entry = current_user.collection_entries.find_by(imdb_id: @imdb_id)
    @in_library = @collection_entry&.library? || false
    @in_wishlist = @collection_entry&.wishlist? || false

    if @type == "show"
      @episode_progress = current_user.playback_progresses.for_show(@imdb_id)
        .index_by { |progress| [ progress.season_number, progress.episode_number ] }
      @selected_season = params[:season]&.to_i || 1
      @progress = current_user.playback_progresses.for_show(@imdb_id)
        .recently_watched.first&.progress_percentage
    else
      # Movie progress
      @progress = current_user.playback_progresses.movies_only
        .find_by(imdb_id: @imdb_id)
        &.progress_percentage
    end
  end

  def status
    imdb_id = params[:imdb_id]
    type = params[:type]
    return if reject_invalid_imdb_id!(imdb_id) || reject_invalid_content_type!(type)

    entry = current_user.collection_entries.find_by(imdb_id: imdb_id)
    render json: { state: entry&.list_state || "none" }
  end

  def episode_streams
    @imdb_id = params[:imdb_id]
    @type = params[:type]
    @season = params[:season]&.to_i
    @episode = params[:episode]&.to_i

    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)

    catalog = Catalog::CinemetaClient.new

    meta = catalog.metadata(@imdb_id, @type)
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
    streams_result = AvailableStreamsService.new(current_user).call(
      imdb_id: @imdb_id,
      type: "show",
      season: @season,
      episode: @episode,
      title: filter_title
    )
    @streams = streams_result.success? ? streams_result.data : []
    @streams_error = streams_result.failure? ? streams_result.error_message : nil

    render layout: false
  end
end
