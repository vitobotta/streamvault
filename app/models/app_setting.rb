# frozen_string_literal: true

# Installation-wide settings an administrator can change without a deploy.
# Credentials are encrypted at rest with Active Record Encryption and are
# never rendered back to the browser.
class AppSetting < ApplicationRecord
  # Columns an administrator may set or clear on the team settings form.
  KEY_COLUMNS = %w[realdebrid_api_key torbox_api_key].freeze

  # The table holds exactly one row.  The unique index on `singleton` makes that
  # a database guarantee: two concurrent first requests can no longer each
  # insert a row and strand one of them with keys that are never read again.
  SINGLETON = true

  encrypts :realdebrid_api_key, deterministic: false
  encrypts :torbox_api_key, deterministic: false

  def self.current
    find_or_create_by!(singleton: SINGLETON)
  rescue ActiveRecord::RecordNotUnique
    find_by!(singleton: SINGLETON)
  end
end
