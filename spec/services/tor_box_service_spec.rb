require "rails_helper"

RSpec.describe TorBoxService do
  subject(:service) { described_class.new("test_torbox_key") }

  let(:user_url) { "https://api.torbox.app/v1/api/user/me" }

  it "verifies a valid key" do
    stub_request(:get, user_url)
      .with(headers: { "Authorization" => "Bearer test_torbox_key" })
      .to_return(status: 200, body: { "success" => true, "data" => { "email" => "user@example.com" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    result = service.verify_key

    expect(result).to be_success
    expect(result.data["data"]["email"]).to eq("user@example.com")
  end

  it "reports an invalid key" do
    stub_request(:get, user_url)
      .to_return(status: 403, body: { "success" => false, "error" => "Invalid API key" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    result = service.verify_key

    expect(result).to be_failure
    expect(result.error_message).to eq("Invalid API key")
  end

  it "reports a timeout" do
    stub_request(:get, user_url).to_timeout

    result = service.verify_key

    expect(result).to be_failure
    expect(result.error_message).to include("timed out")
  end
end
