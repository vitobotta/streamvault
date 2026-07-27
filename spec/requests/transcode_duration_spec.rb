require 'rails_helper'

RSpec.describe "TranscodeDuration", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:media_url) { "https://download.real-debrid.com/d/test.mkv" }
  let(:source_token) { signed_source_for(user, url: media_url, filename: "test.mkv") }

  before do
    sign_in user
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
  end

  describe "GET /transcode/duration" do
    context "when not authenticated" do
      it "redirects to login" do
        sign_out user
        get transcode_duration_path, params: { source: source_token }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    it "rejects an invalid source token" do
      get transcode_duration_path, params: { source: "tampered" }
      expect(response).to have_http_status(:bad_request)
    end

    it "returns duration JSON for a signed source" do
      allow(Media::Transcoder).to receive(:probe_duration).and_return(7200)
      get transcode_duration_path, params: { source: source_token }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["duration"]).to eq(7200)
    end
  end
end
