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

  # Series cards use the total persisted when the series page loaded and the
  # user's local progress rows, so loading the library never calls the
  # catalogue.
  def series_progress_map(entries, progress_rows)
    rows_by_show = progress_rows.select(&:episode?).group_by(&:imdb_id)

    entries.select(&:show?).each_with_object({}) do |entry, result|
      total = entry.series_total_episodes.to_i
      next unless total.positive?

      watched = Array(rows_by_show[entry.imdb_id]).count do |row|
        row.season_number.positive? && row.watched?
      end
      next unless watched.positive?

      watched = [ watched, total ].min
      result[entry.imdb_id] = {
        watched: watched,
        total: total,
        percentage: ((watched.to_f / total) * 100).round,
        complete: watched == total
      }
    end
  end
end
