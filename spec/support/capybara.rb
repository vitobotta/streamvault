# frozen_string_literal: true

require "capybara/cuprite"

Capybara.register_driver :cuprite do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [1440, 900],
    browser_options: { "no-sandbox": nil },
    inspector: ENV["CUPRITE_INSPECTOR"],
    headless: !ENV["CUPRITE_HEADED"],
    slowmo: ENV["CUPRITE_SLOWMO"]&.to_f
  )
end

Capybara.default_driver = :cuprite
Capybara.javascript_driver = :cuprite
Capybara.default_max_wait_time = 5
Capybara.raise_server_errors = true
Capybara.server = :puma, { Silent: true }
