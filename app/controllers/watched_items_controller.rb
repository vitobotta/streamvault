# frozen_string_literal: true

class WatchedItemsController < ApplicationController
  include ContentParamValidation

  before_action :authenticate_user!

  def update
    imdb_id = params[:imdb_id]
    type = params[:type]

    return if reject_invalid_imdb_id!(imdb_id) || reject_invalid_content_type!(type)

    unless parental_content_policy.allowed?(imdb_id)
      redirect_back fallback_location: root_path, alert: "This content is not available for this account."
      return
    end

    if params[:watched].nil?
      redirect_back fallback_location: content_path(type: type, imdb_id: imdb_id), alert: "Watched state is required."
      return
    end
    watched = ActiveModel::Type::Boolean.new.cast(params[:watched])

    result = Playback::WatchedToggle.new(current_user).call(
      imdb_id: imdb_id,
      type: type,
      season: params[:season],
      episode: params[:episode],
      watched: watched,
      title: params[:title],
      poster_url: params[:poster_url],
      duration_seconds: params[:duration_seconds]
    )

    if result.failure?
      redirect_back fallback_location: content_path(type: type, imdb_id: imdb_id), alert: result.error_message
      return
    end

    redirect_back fallback_location: content_path(type: type, imdb_id: imdb_id),
                  notice: watched ? "Marked as watched." : "Marked as unwatched."
  end
end
