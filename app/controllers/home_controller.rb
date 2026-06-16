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
    # Get latest watch history entries that aren't finished (< 95%)
    recent = current_user.watch_history_entries
      .where("progress_percentage < ?", 95)
      .order(watched_at: :desc)

    # Group by content key and get the latest per content
    grouped = recent.group_by do |e|
      e.show_imdb_id.presence || e.imdb_id
    end

    grouped.map do |_key, entries|
      latest = entries.first
      {
        imdb_id: latest.show_imdb_id.presence || latest.imdb_id,
        title: latest.show_title.presence || latest.title,
        poster_url: latest.poster_url,
        content_type: latest.content_type,
        season: latest.season_number,
        episode: latest.episode_number,
        progress_seconds: latest.progress_seconds,
        duration_seconds: latest.duration_seconds,
        progress_percentage: latest.progress_percentage,
        last_watched: latest.watched_at,
        history_id: latest.id
      }
    end.sort_by { |i| -i[:last_watched].to_i }
  end
end
