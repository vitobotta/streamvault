# frozen_string_literal: true

class HomeController < ApplicationController
  before_action :authenticate_user!

  def index
    @continue_watching = ProgressTrackingService.continue_watching(current_user).data || []
    @recently_added = policy_scope(LibraryEntry).recently_added.limit(10)
    @wishlist_preview = policy_scope(WishlistEntry).recently_added.limit(10)
  end
end
