# frozen_string_literal: true

class HlsSession < ApplicationRecord
  HLS_ROOT = Rails.root.join("tmp", "hls").freeze
  SESSION_ID_PATTERN = /\A[0-9a-f]{32}\z/
  SEGMENTS_BEHIND_PLAYHEAD = 6

  belongs_to :user

  validates :session_id, presence: true, uniqueness: true, format: { with: SESSION_ID_PATTERN }

  def self.storage_path(record_id)
    HLS_ROOT.join(Integer(record_id).to_s)
  end

  def storage_path
    raise ArgumentError, "HLS session must be persisted" unless id

    self.class.storage_path(id)
  end

  def playlist_path
    storage_path.join("playlist.m3u8")
  end

  def segment_path(index)
    segment_index = Integer(index)
    raise ArgumentError, "invalid segment index" if segment_index.negative?

    storage_path.join("#{segment_index}.ts")
  end

  def playlist_ready?
    return false unless playlist_path.exist?

    content = playlist_path.read
    content.include?("#EXTINF") || content.include?("#EXT-X-ENDLIST")
  rescue StandardError
    false
  end

  def prune_consumed_segments(current_index)
    delete_before = current_index.to_i - SEGMENTS_BEHIND_PLAYHEAD
    return if delete_before <= 0

    Dir.glob(storage_path.join("[0-9]*.ts")).each do |path|
      index = File.basename(path, ".ts").to_i
      File.delete(path) if index < delete_before
    rescue Errno::ENOENT
      # A concurrent segment request already pruned it.
    end
  end
end
