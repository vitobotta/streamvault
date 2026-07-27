require "rails_helper"
require Rails.root.join("db/migrate/20260722050000_consolidate_playback_progresses").to_s

RSpec.describe ConsolidatePlaybackProgresses do
  let(:database_class) do
    klass = Class.new(ActiveRecord::Base) do
      self.abstract_class = true
    end
    stub_const("ConsolidatePlaybackProgressesDatabaseRecord", klass)
    klass.establish_connection(adapter: "sqlite3", database: ":memory:")
    klass
  end
  let(:connection) { database_class.connection }
  let(:migration) do
    migration_connection = connection
    described_class.new.tap do |instance|
      instance.define_singleton_method(:connection) { migration_connection }
    end
  end

  before do
    connection.create_table(:users)
    connection.create_table(:watch_history_entries) do |table|
      table.references :user, null: false
      table.string :imdb_id, null: false
      table.integer :content_type, default: 0, null: false
      table.integer :season_number, default: 0, null: false
      table.integer :episode_number, default: 0, null: false
      table.string :title, null: false
      table.string :poster_url
      table.integer :progress_seconds, default: 0, null: false
      table.integer :duration_seconds, default: 0, null: false
      table.datetime :watched_at, null: false
      table.string :show_imdb_id
      table.string :show_title
      table.integer :progress_percentage, default: 0, null: false
      table.timestamps
    end
    connection.create_table(:episode_progresses) do |table|
      table.references :user, null: false
      table.string :show_imdb_id, null: false
      table.string :show_title, null: false
      table.integer :season_number, null: false
      table.integer :episode_number, null: false
      table.integer :progress_seconds, default: 0, null: false
      table.integer :duration_seconds, default: 0, null: false
      table.datetime :last_watched_at, null: false
      table.timestamps
    end
    connection.execute("INSERT INTO users (id) VALUES (1)")
    connection.execute(<<~SQL.squish)
      INSERT INTO episode_progresses
        (user_id, show_imdb_id, show_title, season_number, episode_number,
         progress_seconds, duration_seconds, last_watched_at, created_at, updated_at)
      VALUES
        (1, 'tt0903747', 'Breaking Bad', 1, 2, 1200, 2880,
         '2026-07-27 12:00:00', '2026-07-27 12:00:00', '2026-07-27 12:00:00')
    SQL
  end

  after do
    database_class.connection_pool.disconnect!
  end

  it "restores episode progress during an up and down round trip" do
    migration.migrate(:up)
    migration.migrate(:down)

    progress = connection.select_one(<<~SQL.squish)
      SELECT show_imdb_id, show_title, season_number, episode_number,
             progress_seconds, duration_seconds
      FROM episode_progresses
      WHERE user_id = 1
    SQL

    expect(progress).to include(
      "show_imdb_id" => "tt0903747",
      "show_title" => "Breaking Bad",
      "season_number" => 1,
      "episode_number" => 2,
      "progress_seconds" => 1_200,
      "duration_seconds" => 2_880
    )
  end
end
