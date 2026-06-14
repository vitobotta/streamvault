FactoryBot.define do
  factory :episode_progress do
    user
    show_imdb_id { "tt1234567" }
    show_title { Faker::App.name }
    season_number { 1 }
    sequence(:episode_number) { |n| n }
    progress_seconds { 1200 }
    duration_seconds { 2400 }
    last_watched_at { 1.hour.ago }
  end
end
