# frozen_string_literal: true

class CollectionsController < ApplicationController
  WRITE_ATTEMPTS = 2

  before_action :authenticate_user!

  def update
    state = params[:state].to_s
    unless CollectionEntry.list_states.key?(state) || state == "none"
      render json: { error: "Invalid collection state" }, status: :unprocessable_entity
      return
    end

    if state == "none"
      current_user.collection_entries.where(imdb_id: entry_params[:imdb_id]).delete_all
      respond_with_state("none")
      return
    end

    entry = persist_entry!(state)
    respond_with_state(entry.list_state)
  rescue ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: e.record.errors.full_messages.join(", ") }
      format.json { render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity }
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "Collection changed concurrently. Please try again." }
      format.json { render json: { error: "Collection changed concurrently. Please try again." }, status: :conflict }
    end
  end

  private

  def persist_entry!(state)
    attempts = 0
    attributes = entry_params.except(:imdb_id).merge(list_state: state)
    scope = current_user.collection_entries

    begin
      entry = scope.find_by(imdb_id: entry_params[:imdb_id])
      entry ||= scope.create_or_find_by!(imdb_id: entry_params[:imdb_id]) do |candidate|
        candidate.assign_attributes(attributes)
      end
      entry.with_lock { entry.update!(attributes) }
      entry
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
      attempts += 1
      retry if attempts < WRITE_ATTEMPTS

      raise
    end
  end

  def respond_with_state(state)
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, notice: "Collection updated." }
      format.json { render json: { ok: true, state: state } }
    end
  end

  def entry_params
    params.require(:collection_entry).permit(:content_type, :imdb_id, :title, :poster_url, :year)
  end
end
