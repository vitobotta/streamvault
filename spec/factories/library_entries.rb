FactoryBot.define do
  factory :library_entry do
    user
    content_type { :movie }
    sequence(:imdb_id) { |n| "tt#{n.to_s.rjust(7, '0')}" }
    title { Faker::Movie.title }
    poster_url { "https://example.com/poster.jpg" }
    year { rand(1970..2025) }
    watch_status { :not_started }

    trait :movie do
      content_type { :movie }
    end

    trait :show do
      content_type { :show }
    end

    trait :watching do
      watch_status { :watching }
      current_season { 1 }
      current_episode { 1 }
    end

    trait :finished do
      watch_status { :finished }
    end
  end
end
