# frozen_string_literal: true

class ApplicationPolicy < ActionPolicy::Base
  # Default: user can only access their own records
  def show?
    owner?
  end

  def create?
    true
  end

  def update?
    owner?
  end

  def destroy?
    owner?
  end

  private

  def owner?
    record.user_id == user.id
  end

  # Default scope: filter to current user's records
  scope_for :relation do |relation|
    relation.where(user: user)
  end
end
