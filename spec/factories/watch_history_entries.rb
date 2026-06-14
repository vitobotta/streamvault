FactoryBot.define do
  factory :watch_history_entry do
    user
    content_type { :movie }
    sequence(:imdb_id) { |n| "tt#{n.to_s.rjust(7, '0')}" }
    title { Faker::Movie.title }
    poster_url { "https://example.com/poster.jpg" }
    watched_at { 1.hour.ago }
    progress_seconds { 3600 }
    duration_seconds { 7200 }
    progress_percentage { 50 }

    trait :movie do
      content_type { :movie }
    end

    trait :episode do
      content_type { :episode }
      season_number { 1 }
      episode_number { 1 }
      show_imdb_id { "tt1234567" }
      show_title { Faker::App.name }
    end
  end
end
