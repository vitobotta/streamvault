# frozen_string_literal: true

class PlaylistItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_playlist
  before_action :set_item, only: %i[destroy move]

  def create
    attributes = item_params
    unless PlaylistItem.content_types.key?(attributes[:content_type].to_s)
      redirect_to playlist_path(@playlist), alert: "Invalid content type."
      return
    end
    unless parental_content_policy.allowed?(attributes[:imdb_id])
      redirect_to playlist_path(@playlist), alert: "That title is not available for this account."
      return
    end

    item = @playlist.playlist_items.find_or_initialize_by(
      imdb_id: attributes[:imdb_id],
      content_type: attributes[:content_type]
    )
    if item.persisted?
      redirect_to playlist_path(@playlist), notice: "Already in this playlist."
      return
    end

    item.assign_attributes(attributes.except(:imdb_id, :content_type))
    if item.save
      redirect_to playlist_path(@playlist), notice: "Added to #{@playlist.name}."
    else
      redirect_to playlist_path(@playlist), alert: item.errors.full_messages.to_sentence
    end
  end

  def destroy
    @item.destroy!
    compact_positions
    redirect_to playlist_path(@playlist), notice: "Removed from playlist."
  end

  def move
    unless @item.move!(params[:direction])
      redirect_to playlist_path(@playlist), alert: "That item is already at the edge of the playlist."
      return
    end

    redirect_to playlist_path(@playlist), notice: "Playlist order updated."
  end

  private

  def set_playlist
    @playlist = current_user.playlists.find(params[:playlist_id])
  end

  def set_item
    @item = @playlist.playlist_items.find(params[:id])
  end

  def item_params
    params.require(:playlist_item).permit(:imdb_id, :content_type, :title, :poster_url, :year)
  end

  def compact_positions
    @playlist.playlist_items.ordered.each_with_index do |item, index|
      item.update_column(:position, index) unless item.position == index
    end
  end
end
