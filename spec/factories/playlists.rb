FactoryBot.define do
  factory :playlist do
    user
    sequence(:name) { |number| "Playlist #{number}" }
    description { nil }
  end

  factory :playlist_item do
    playlist
    content_type { :movie }
    sequence(:imdb_id) { |number| "tt#{number.to_s.rjust(7, '0')}" }
    title { Faker::Movie.title }
    poster_url { "https://example.com/poster.jpg" }
    year { rand(1970..2025) }

    trait :show do
      content_type { :show }
    end
  end
end
