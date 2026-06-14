class AddProfileToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :display_name, :string
    add_column :users, :realdebrid_api_key, :text
  end
end
