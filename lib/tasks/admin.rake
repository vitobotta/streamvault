# frozen_string_literal: true

namespace :admin do
  desc "Grant the administrator role to an account (defaults to the oldest account)"
  task :promote, [ :email ] => :environment do |_task, args|
    scope = User.order(:id)
    scope = scope.where(email: args[:email]) if args[:email].present?
    user = scope.first
    abort(args[:email].present? ? "No account with #{args[:email]}" : "No accounts yet") unless user

    user.update!(admin: true)
    puts "#{user.email} is now an administrator."
  end

  desc "List the accounts that can reach the Team page"
  task list: :environment do
    admins = User.where(admin: true).order(:id).pluck(:email)
    puts(admins.empty? ? "No administrators yet; run bin/rails admin:promote" : admins)
  end
end
