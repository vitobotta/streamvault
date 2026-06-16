class AddLanguagePreferencesAndCodecFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :preferred_languages, :text
    add_column :users, :default_language, :string
  end
end
