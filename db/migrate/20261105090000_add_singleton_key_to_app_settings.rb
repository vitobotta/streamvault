# frozen_string_literal: true

class AddSingletonKeyToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :singleton, :boolean, default: true, null: false
    # An install that raced its first two requests can hold duplicate rows.
    # Only the oldest one is read, so the others would be lost on index creation.
    execute "DELETE FROM app_settings WHERE id NOT IN (SELECT MIN(id) FROM app_settings)"
    add_index :app_settings, :singleton, unique: true
  end

  def down
    remove_index :app_settings, :singleton
    remove_column :app_settings, :singleton
  end
end
