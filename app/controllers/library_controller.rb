# frozen_string_literal: true

class LibraryController < ApplicationController
  before_action :authenticate_user!

  def index
    entries = current_user.collection_entries.library
    entries = entries.by_type(params[:type]) if params[:type].present?
    entries = entries.recently_added
    @pagination = PageSlice.from_relation(
      entries,
      page: params.fetch(:page, 1),
      per_page: params.fetch(:per_page, 25)
    )
    # Child accounts only ever see titles within their rating limit.
    @entries = parental_content_policy.filter(@pagination.items)

    progress_rows = current_user.playback_progresses.where(imdb_id: @entries.map(&:imdb_id)).to_a
    @progress_map = progress_rows.group_by(&:imdb_id).transform_values do |rows|
      rows.map(&:progress_percentage).max.to_i
    end
    @movie_watched_map = progress_rows.select(&:movie?).group_by(&:imdb_id).transform_values do |rows|
      rows.any?(&:watched?)
    end
    @series_progress_map = series_progress_map(@entries, progress_rows)
  end

  private

  # Series cards need the released-episode total, which only the catalogue
  # knows. Only shows with at least one completed episode are looked up, so a
  # library without watched series makes no metadata requests.
  def series_progress_map(entries, progress_rows)
    rows_by_show = progress_rows.group_by(&:imdb_id)
    catalog = Catalog::CinemetaClient.new

    entries.select(&:show?).each_with_object({}) do |entry, result|
      finished = Array(rows_by_show[entry.imdb_id]).select(&:watched?).index_by do |row|
        [ row.season_number, row.episode_number ]
      end
      next if finished.empty?

      metadata = catalog.metadata(entry.imdb_id, "show", include_ratings: false)
      next if metadata.failure?

      progress = Playback::SeriesProgress.new(metadata.data[:episodes], finished: finished)
      next unless progress.watched_episodes.positive?

      result[entry.imdb_id] = progress.summary
    end
  end
end
