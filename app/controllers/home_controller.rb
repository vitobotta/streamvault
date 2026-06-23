# frozen_string_literal: true

class HomeController < ApplicationController
  before_action :authenticate_user!

  def index
    torrentio = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key)

    @continue_watching = fetch_continue_watching
    @recently_added = policy_scope(LibraryEntry).where("created_at > ?", 2.weeks.ago).recently_added.limit(20)
    @wishlist_preview = policy_scope(WishlistEntry).recently_added.limit(20)
    @popular = torrentio.popular("movie", limit: 20)
    @popular_shows = torrentio.popular("show", limit: 20)
    @trending = torrentio.trending("movie", limit: 20)
    @trending_shows = torrentio.trending("show", limit: 20)
  end

  private

  def fetch_continue_watching
    current_user.watch_history_entries
      .where("progress_percentage < ?", 95)
      .order(watched_at: :desc)
      .limit(20)
      .map do |e|
        {
          imdb_id: e.show_imdb_id.presence || e.imdb_id,
          title: e.show_title.presence || e.title,
          poster_url: e.poster_url,
          content_type: e.content_type,
          season: e.season_number,
          episode: e.episode_number,
          progress_seconds: e.progress_seconds,
          duration_seconds: e.duration_seconds,
          progress_percentage: e.progress_percentage,
          last_watched: e.watched_at,
          history_id: e.id
        }
      end.sort_by { |i| -i[:last_watched].to_i }
  end
end
