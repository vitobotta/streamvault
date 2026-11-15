# frozen_string_literal: true

class PlaylistsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_playlist, only: %i[show update destroy]

  def index
    @playlists = playlists_for_index
    @playlist = current_user.playlists.new
    build_item_counts
  end

  def show
    @items = parental_content_policy.filter(@playlist.playlist_items.ordered)
    @ordered_ids = @playlist.playlist_items.ordered.pluck(:id)
  end

  def create
    @playlist = current_user.playlists.new(playlist_params)
    item_attributes = nested_item_params
    if item_attributes.present? && !PlaylistItem.content_types.key?(item_attributes[:content_type].to_s)
      redirect_to playlists_path, alert: "Invalid content type."
      return
    end
    if item_attributes.present? && !parental_content_policy.allowed?(item_attributes[:imdb_id])
      redirect_to playlists_path, alert: content_restricted_message
      return
    end

    Playlist.transaction do
      @playlist.save!
      @playlist.playlist_items.create!(item_attributes) if item_attributes.present?
    end
    redirect_to playlist_path(@playlist), notice: "Playlist created."
  rescue ActiveRecord::RecordInvalid => e
    @playlists = playlists_for_index
    build_item_counts
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :index, status: :unprocessable_entity
  end

  def update
    if @playlist.update(playlist_params)
      redirect_to playlist_path(@playlist), notice: "Playlist updated."
    else
      @items = parental_content_policy.filter(@playlist.playlist_items.ordered)
    @ordered_ids = @playlist.playlist_items.ordered.pluck(:id)
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    @playlist.destroy!
    redirect_to playlists_path, notice: "Playlist deleted."
  end

  private

  def set_playlist
    @playlist = current_user.playlists.find(params[:id])
  end

  def playlists_for_index
    current_user.playlists.includes(:playlist_items).order(updated_at: :desc)
  end

  # :index is rendered from both index and the create failure path, which
  # runs with playlists already on the account, so the counts have to be
  # built there too or the view fetches from nil.
  def build_item_counts
    @item_counts = @playlists.index_with do |playlist|
      items = playlist.playlist_items.to_a
      visible = parental_content_policy.filter(items).size
      { visible: visible, hidden: items.size - visible }
    end
  end

  def playlist_params
    params.require(:playlist).permit(:name, :description)
  end

  def nested_item_params
    return if params[:playlist_item].blank?

    params.require(:playlist_item).permit(:imdb_id, :content_type, :title, :poster_url, :year).to_h
  end

  def content_restricted_message
    "That title is not available for this account."
  end
end
