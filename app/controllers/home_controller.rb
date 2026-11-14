# frozen_string_literal: true

class HomeController < ApplicationController
  before_action :authenticate_user!

  def index
    policy = parental_content_policy
    catalog = Catalog::CinemetaClient.new

    # Local queries run while the four remote catalogs load.
    @continue_watching = policy.filter(fetch_continue_watching)
    @recently_added = policy.filter(current_user.collection_entries.library.where("created_at > ?", 2.weeks.ago).recently_added.limit(20))
    @wishlist_preview = policy.filter(current_user.collection_entries.wishlist.recently_added.limit(20))

    catalogs_thread = Thread.new { HomeCatalogService.new(catalog).call }

    @recommendations = filtered_result(policy, RecommendationService.for(current_user))
    catalogs = catalogs_thread.value
    @popular = filtered_result(policy, catalogs.fetch(:popular))
    @popular_shows = filtered_result(policy, catalogs.fetch(:popular_shows))
    @trending = filtered_result(policy, catalogs.fetch(:trending))
    @trending_shows = filtered_result(policy, catalogs.fetch(:trending_shows))
  end

  private

  # Child accounts only ever see titles within their rating limit.
  def filtered_result(policy, result)
    return result unless result.success?

    ServiceResult.success(policy.filter(result.data))
  end

  def fetch_continue_watching
    result = Playback::ContinueWatchingQuery.new(current_user).call
    result.success? ? result.data : []
  end
end
