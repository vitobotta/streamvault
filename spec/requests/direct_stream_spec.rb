require 'rails_helper'

RSpec.describe "DirectStream", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:media_url) { "https://download.real-debrid.com/d/video.mp4" }
  let(:source_token) { signed_source_for(user, url: media_url, filename: "video.mp4") }

  before do
    sign_in user
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
  end

  describe "GET /direct_stream" do
    it "requires authentication" do
      sign_out user

      get direct_stream_path, params: { source: source_token }

      expect(response).to redirect_to(new_user_session_path)
    end

    it "rejects a missing or tampered source token" do
      get direct_stream_path, params: { source: "tampered" }

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a source token issued to another user" do
      other_user = create(:user)
      other_source = signed_source_for(other_user, url: media_url)

      get direct_stream_path, params: { source: other_source }

      expect(response).to have_http_status(:bad_request)
    end

    it "forwards byte ranges and logs complete byte accounting" do
      allow(Rails.logger).to receive(:info)
      stub_request(:get, media_url)
        .with(
          headers: {
            "Authorization" => "Bearer test_key",
            "Range" => "bytes=10-13"
          }
        )
        .to_return(
          status: 206,
          body: "data",
          headers: {
            "Content-Type" => "video/mp4",
            "Content-Length" => "4",
            "Content-Range" => "bytes 10-13/100"
          }
        )

      get direct_stream_path,
        params: { source: source_token, playback_id: "playback-1" },
        headers: { "Range" => "bytes=10-13" }

      expect(response).to have_http_status(:partial_content)
      expect(response.body).to eq("data")
      expect(response.headers["Content-Range"]).to eq("bytes 10-13/100")
      expect(Rails.logger).to have_received(:info).with(
        /\[DirectStream\].*playback_id=playback-1.*range=bytes=10-13.*expected_bytes=4.*written_bytes=4.*outcome=complete/
      )
    end

    it "logs upstream timeouts instead of silently truncating the response" do
      allow(Rails.logger).to receive(:warn)
      stub_request(:get, media_url).to_timeout

      get direct_stream_path, params: {
        source: source_token,
        playback_id: "playback-2"
      }

      expect(response).to have_http_status(:bad_gateway)
      expect(Rails.logger).to have_received(:warn).with(
        /\[DirectStream\].*playback_id=playback-2.*upstream_error=Net::OpenTimeout/
      )
    end
  end
end
