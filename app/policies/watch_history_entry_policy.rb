# frozen_string_literal: true

class WatchHistoryEntryPolicy < ApplicationPolicy
  # Allow clear_all for own entries
  def clear_all?
    true
  end
end
