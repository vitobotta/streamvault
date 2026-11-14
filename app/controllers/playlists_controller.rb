# frozen_string_literal: true

class PlaylistsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_playlist, only: %i[show update destroy]

  def index
    @playlists = playlists_for_index
    @playlist = current_user.playlists.new
  end

  def show
    @items = parental_content_policy.filter(@playlist.playlist_items.ordered)
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
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :index, status: :unprocessable_entity
  end

  def update
    if @playlist.update(playlist_params)
      redirect_to playlist_path(@playlist), notice: "Playlist updated."
    else
      @items = parental_content_policy.filter(@playlist.playlist_items.ordered)
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
