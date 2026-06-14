# frozen_string_literal: true

class WishlistEntryPolicy < ApplicationPolicy
  def move_to_library?
    owner?
  end
end
