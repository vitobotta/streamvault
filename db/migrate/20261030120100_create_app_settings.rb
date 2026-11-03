# frozen_string_literal: true

class CreateAppSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :app_settings do |t|
      t.text :realdebrid_api_key
      t.text :torbox_api_key

      t.timestamps
    end
  end
end
