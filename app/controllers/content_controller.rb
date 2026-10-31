# frozen_string_literal: true

class ContentController < ApplicationController
  include ContentParamValidation
  before_action :authenticate_user!

  def show
    @imdb_id = params[:imdb_id]
    @type = params[:type]

    return if reject_invalid_imdb_id!(@imdb_id) || reject_invalid_content_type!(@type)
    return reject_restricted_content! unless parental_content_policy.allowed?(@imdb_id)

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
      @episode_finished = @episode_progress.transform_values do |progress|
        PlaybackCompletionPolicy.episode_finished?(progress)
      end
      @selected_season = params[:season]&.to_i || 1
      series_progress = Playback::SeriesProgress.new(@metadata&.dig(:episodes), finished: @episode_finished)
      @season_progress = series_progress.seasons
      selected_season = @season_progress[@selected_season]
      @season_watched = selected_season && selected_season[:watched] == selected_season[:total]
      @series_watched = series_progress.complete?
      @series_watched_episodes = series_progress.watched_episodes
      @series_total_episodes = series_progress.total_episodes
      @series_progress_percentage = series_progress.percentage
    else
      @movie_progress = current_user.playback_progresses.movies_only.find_by(imdb_id: @imdb_id)
      @movie_watched = @movie_progress.present? && PlaybackCompletionPolicy.movie_finished?(@movie_progress)
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
    return head :forbidden unless parental_content_policy.allowed?(@imdb_id)

    catalog = Catalog::CinemetaClient.new
    meta = catalog.metadata(@imdb_id, @type, include_ratings: false)
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

  private

  # Child accounts may not access titles above their rating limit — never
  # return their metadata or streams, even via a direct item URL.
  def reject_restricted_content!
    respond_to do |format|
      format.html { redirect_to root_path, alert: "This content is not available for this account." }
      format.any { head :forbidden }
    end
  end
end
