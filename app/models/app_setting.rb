# frozen_string_literal: true

# Installation-wide settings an administrator can change without a deploy.
# Credentials are encrypted at rest with Active Record Encryption and are
# never rendered back to the browser.
class AppSetting < ApplicationRecord
  encrypts :realdebrid_api_key, deterministic: false
  encrypts :torbox_api_key, deterministic: false

  # The table holds a single row.  Creating it lazily keeps existing installs
  # working without a data migration.
  def self.current
    first_or_create!
  end
end
