# frozen_string_literal: true

class AddCompletedToPlaybackProgresses < ActiveRecord::Migration[8.1]
  def change
    add_column :playback_progresses, :completed, :boolean, default: false, null: false
  end
end
