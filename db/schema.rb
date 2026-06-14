# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_14_175419) do
  create_table "episode_progresses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_seconds", default: 0, null: false
    t.integer "episode_number", null: false
    t.datetime "last_watched_at", null: false
    t.integer "progress_seconds", default: 0, null: false
    t.integer "season_number", null: false
    t.string "show_imdb_id", null: false
    t.string "show_title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "show_imdb_id", "season_number", "episode_number"], name: "idx_episode_progresses_unique", unique: true
    t.index ["user_id", "show_imdb_id"], name: "index_episode_progresses_on_user_id_and_show_imdb_id"
    t.index ["user_id"], name: "index_episode_progresses_on_user_id"
  end

  create_table "library_entries", force: :cascade do |t|
    t.integer "content_type", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "current_episode"
    t.integer "current_season"
    t.string "imdb_id", null: false
    t.string "poster_url"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "watch_status", default: 0, null: false
    t.integer "year"
    t.index ["content_type"], name: "index_library_entries_on_content_type"
    t.index ["user_id", "imdb_id"], name: "index_library_entries_on_user_id_and_imdb_id", unique: true
    t.index ["user_id"], name: "index_library_entries_on_user_id"
    t.index ["watch_status"], name: "index_library_entries_on_watch_status"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.text "realdebrid_api_key"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "watch_history_entries", force: :cascade do |t|
    t.integer "content_type", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "duration_seconds", default: 0, null: false
    t.integer "episode_number"
    t.string "imdb_id", null: false
    t.string "poster_url"
    t.integer "progress_percentage", default: 0, null: false
    t.integer "progress_seconds", default: 0, null: false
    t.integer "season_number"
    t.string "show_imdb_id"
    t.string "show_title"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.datetime "watched_at", null: false
    t.index ["show_imdb_id"], name: "index_watch_history_entries_on_show_imdb_id"
    t.index ["user_id", "imdb_id"], name: "index_watch_history_entries_on_user_id_and_imdb_id"
    t.index ["user_id"], name: "index_watch_history_entries_on_user_id"
    t.index ["watched_at"], name: "index_watch_history_entries_on_watched_at"
  end

  create_table "wishlist_entries", force: :cascade do |t|
    t.integer "content_type", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "imdb_id", null: false
    t.string "poster_url"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "year"
    t.index ["user_id", "imdb_id"], name: "index_wishlist_entries_on_user_id_and_imdb_id", unique: true
    t.index ["user_id"], name: "index_wishlist_entries_on_user_id"
  end

  add_foreign_key "episode_progresses", "users"
  add_foreign_key "library_entries", "users"
  add_foreign_key "watch_history_entries", "users"
  add_foreign_key "wishlist_entries", "users"
end
