require 'rails_helper'

RSpec.describe "Transcode", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }

  before do
    sign_in user
  end

  describe "GET /transcode" do
    it "rejects non-HTTP media URLs before invoking ffmpeg" do
      expect(TranscodeService).not_to receive(:transcode_to_fmp4)

      get transcode_stream_path, params: { url: "file:///etc/passwd" }

      expect(response).to have_http_status(:bad_request)
    end
  end
end
