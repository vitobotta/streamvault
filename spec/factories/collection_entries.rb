FactoryBot.define do
  factory :collection_entry do
    user
    content_type { :movie }
    list_state { :library }
    sequence(:imdb_id) { |number| "tt#{number.to_s.rjust(7, '0')}" }
    title { Faker::Movie.title }
    poster_url { "https://example.com/poster.jpg" }
    year { rand(1970..2025) }

    trait :movie do
      content_type { :movie }
    end

    trait :show do
      content_type { :show }
    end

    trait :wishlist do
      list_state { :wishlist }
    end

    trait :library do
      list_state { :library }
    end
  end
end
