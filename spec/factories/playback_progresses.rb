FactoryBot.define do
  factory :playback_progress do
    user
    content_type { :movie }
    sequence(:imdb_id) { |number| "tt#{number.to_s.rjust(7, '0')}" }
    title { Faker::Movie.title }
    poster_url { "https://example.com/poster.jpg" }
    watched_at { 1.hour.ago }
    progress_seconds { 3600 }
    duration_seconds { 7200 }
    season_number { 0 }
    episode_number { 0 }

    trait :movie do
      content_type { :movie }
      season_number { 0 }
      episode_number { 0 }
    end

    trait :episode do
      content_type { :episode }
      season_number { 1 }
      episode_number { 1 }
    end
  end
end
