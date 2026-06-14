# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'

# SimpleCov must be started BEFORE requiring application code
require 'simplecov'
SimpleCov.start :rails do
  enable_coverage :branch
  minimum_coverage line: 85, branch: 50
  add_filter '/spec/'
  add_filter '/config/'
  add_filter '/vendor/'
  track_files 'app/**/*.rb'
end

ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'

# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?

require 'rspec/rails'
require 'webmock/rspec'
require 'action_policy/rspec'

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories.
Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# Ensures that the test database schema matches the current schema file.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # FactoryBot
  config.include FactoryBot::Syntax::Methods

  # Devise helpers for request specs
  config.include Devise::Test::IntegrationHelpers, type: :request
  config.include Devise::Test::IntegrationHelpers, type: :system

  # Use transactional fixtures (DatabaseCleaner will handle strategy)
  config.use_transactional_fixtures = false

  # Infer spec type from file location
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!

  # DatabaseCleaner configuration
  config.before(:suite) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end

  config.around(:each) do |example|
    DatabaseCleaner.cleaning do
      example.run
    end
  end

  # WebMock configuration
  config.before(:each) do
    WebMock.reset!
    # Block all HTTP requests by default; stub per-test
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  # ActionPolicy RSpec matchers are loaded via 'action_policy/rspec'
end

# Shoulda::Matchers configuration
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
