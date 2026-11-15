# frozen_string_literal: true

class AddDebridAccountFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :admin, :boolean, default: false, null: false
    add_column :users, :torbox_api_key, :text
    add_column :users, :debrid_service, :string, default: "realdebrid", null: false
  end
end
