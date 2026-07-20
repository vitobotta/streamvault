# frozen_string_literal: true

class HomeController < ApplicationController
  before_action :authenticate_user!

  def index
    torrentio = TorrentioService.new(rd_api_key: current_user.realdebrid_api_key)
    excluded_recommendation_ids = RecommendationService.excluded_imdb_ids(current_user)
    visible_recommendations = policy_scope(Recommendation)
      .where.not(imdb_id: excluded_recommendation_ids)
      .ordered
      .limit(20)
    @recommendations = ServiceResult.success(
      visible_recommendations.map { |r|
        { tmdb_id: r.tmdb_id, imdb_id: r.imdb_id, title: r.title, poster_url: r.poster_url, type: r.content_type, year: r.year }
      }
    )
    @continue_watching = fetch_continue_watching
    @recently_added = policy_scope(LibraryEntry).where("created_at > ?", 2.weeks.ago).recently_added.limit(20)
    @wishlist_preview = policy_scope(WishlistEntry).recently_added.limit(20)
    # Run the four catalog calls concurrently so a slow cinemeta
    # round-trip doesn't block the others (each has its own timeout).
    popular_thread = Thread.new { torrentio.popular("movie", limit: 20) }
    popular_shows_thread = Thread.new { torrentio.popular("show", limit: 20) }
    trending_thread = Thread.new { torrentio.trending("movie", limit: 20) }
    trending_shows_thread = Thread.new { torrentio.trending("show", limit: 20) }
    @popular = popular_thread.value
    @popular_shows = popular_shows_thread.value
    @trending = trending_thread.value
    @trending_shows = trending_shows_thread.value
  end

  private

  def fetch_continue_watching
    result = ProgressTrackingService.continue_watching(current_user)
    result.success? ? result.data : []
  end
end
