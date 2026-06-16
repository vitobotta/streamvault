require 'rails_helper'

RSpec.describe "Home", type: :request do
  let(:user) { create(:user) }

  before do
    # Stub all Cinemeta catalog endpoints used by HomeController
    %w[movie series].each do |type|
      %w[top year imdbRating].each do |cat|
        stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/#{type}/#{cat}})
          .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })
      end
    end
  end

  describe "GET /" do
    context "when not authenticated" do
      it "redirects to login" do
        get root_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get root_path
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
