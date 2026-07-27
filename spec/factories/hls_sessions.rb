FactoryBot.define do
  factory :hls_session do
    user
    session_id { SecureRandom.hex(16) }
    pid { 12_345 }
  end
end
