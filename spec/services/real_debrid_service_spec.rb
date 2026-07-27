require 'rails_helper'

RSpec.describe RealDebridService do
  subject(:service) { described_class.new("test_api_key_123") }

  let(:user_url) { "https://api.real-debrid.com/rest/1.0/user" }

  describe "#verify_key" do
    it "returns user information for a valid key" do
      stub_request(:get, user_url)
        .with(headers: { "Authorization" => "Bearer test_api_key_123" })
        .to_return(
          status: 200,
          body: { "id" => "12345", "username" => "testuser", "type" => "premium" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.verify_key

      expect(result).to be_success
      expect(result.data["username"]).to eq("testuser")
    end

    it "returns the provider error for an invalid key" do
      stub_request(:get, user_url)
        .to_return(
          status: 401,
          body: { "error" => "Bad token", "error_code" => 8 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.verify_key

      expect(result).to be_failure
      expect(result.error_message).to eq("Bad token")
      expect(result.error_code).to eq(401)
    end

    it "contains provider timeouts" do
      allow_any_instance_of(Faraday::Connection).to receive(:get).and_raise(Faraday::TimeoutError)

      result = service.verify_key

      expect(result).to be_failure
      expect(result.error_message).to eq("Request timed out")
    end
  end
end
