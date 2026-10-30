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
  end
end
