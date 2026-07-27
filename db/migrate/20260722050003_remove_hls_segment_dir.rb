# frozen_string_literal: true

class RemoveHlsSegmentDir < ActiveRecord::Migration[8.1]
  def change
    remove_column :hls_sessions, :segment_dir, :string
  end
end
