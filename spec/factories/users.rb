FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    display_name { Faker::Name.name }
    realdebrid_api_key { nil }
  end
end
