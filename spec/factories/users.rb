FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    realdebrid_api_key { nil }
    torbox_api_key { nil }
    debrid_service { "realdebrid" }
    admin { false }
    # Set language defaults explicitly so the factory doesn't depend on
    # the before_validation :set_default_languages callback firing — if
    # that callback ever changes, every factory-built user would have
    # nil languages and fail validations downstream.
    preferred_languages { [ "ENG" ] }
    default_language { "ENG" }

    trait :with_realdebrid_key do
      realdebrid_api_key { "TEST_RD_KEY_#{SecureRandom.hex(8)}" }
    end

    trait :with_torbox_key do
      torbox_api_key { "TEST_TB_KEY_#{SecureRandom.hex(8)}" }
      debrid_service { "torbox" }
    end

    trait :admin do
      admin { true }
    end

    # Age-restricted profile: toggled on with a settings lock ("lock-1234")
    # and an age cap of 13.
    trait :age_restricted do
      child_account { true }
      max_rating_age { 13 }
      child_lock_password { "lock-1234" }
    end
  end
end
