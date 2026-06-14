FactoryBot.define do
  factory :wishlist_entry do
    user
    content_type { :movie }
    sequence(:imdb_id) { |n| "tt#{n.to_s.rjust(7, '0')}" }
    title { Faker::Movie.title }
    poster_url { "https://example.com/poster.jpg" }
    year { rand(1970..2025) }

    trait :movie do
      content_type { :movie }
    end

    trait :show do
      content_type { :show }
    end
  end
end
