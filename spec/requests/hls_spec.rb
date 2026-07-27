# frozen_string_literal: true

require "rails_helper"

RSpec.describe "HLS streaming", type: :request do
  let(:user) { create(:user, realdebrid_api_key: "testkey") }
  let(:media_url) { "https://download.real-debrid.com/d/test.mp4" }
  let(:source_token) { signed_source_for(user, url: media_url, filename: "test.mp4") }

  before do
    sign_in user
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("download.real-debrid.com", nil, :UNSPEC, :STREAM)
      .and_return([ Addrinfo.ip("199.115.115.1") ])
  end

  describe "POST /hls/start" do
    context "with an invalid source" do
      it "returns bad_request" do
        post "/hls/start", params: { source: "tampered" }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq("Invalid stream source")
      end
    end

    context "with valid URL but ffmpeg failure" do
      it "returns bad_gateway when transcode fails" do
        allow(Media::Transcoder).to receive(:transcode_to_hls)
          .and_raise(Media::Transcoder::TranscodeError, "FFmpeg failed")

        post "/hls/start", params: { source: source_token }
        expect(response).to have_http_status(:bad_gateway)
      end
    end
  end

  describe "GET /hls/:id/playlist.m3u8" do
    it "returns 404 for unknown session" do
      get "/hls/nonexistent/playlist.m3u8"
      expect(response).to have_http_status(:not_found)
    end

    context "with a valid session" do
      let(:session_id) { SecureRandom.hex(16) }
      let!(:session) { create(:hls_session, user: user, session_id: session_id, pid: 99_999) }
      let(:segment_dir) { session.storage_path }
      let(:playlist_content) do
        <<~PLAYLIST
          #EXTM3U
          #EXT-X-VERSION:3
          #EXT-X-TARGETDURATION:4
          #EXT-X-MEDIA-SEQUENCE:0
          #EXT-X-PLAYLIST-TYPE:EVENT
          #EXTINF:4.000000,
          0.ts
          #EXT-X-ENDLIST
        PLAYLIST
      end

      before do
        FileUtils.mkdir_p(segment_dir)
        File.write(File.join(segment_dir, "playlist.m3u8"), playlist_content)
        File.write(File.join(segment_dir, "0.ts"), "dummy_ts_data")
      end

      after do
        FileUtils.rm_rf(segment_dir)
        session.destroy if session.persisted?
      end

      it "returns the playlist with correct Content-Type" do
        get "/hls/#{session_id}/playlist.m3u8"
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/vnd.apple.mpegurl")
        expect(response.body).to start_with("#EXTM3U")
      end

      it "works without authentication (iOS media requests don't send cookies)" do
        sign_out user
        get "/hls/#{session_id}/playlist.m3u8"
        expect(response).to have_http_status(:ok)
        expect(response.body).to start_with("#EXTM3U")
      end

      it "returns 202 when playlist file is not ready yet" do
        File.delete(File.join(segment_dir, "playlist.m3u8"))
        get "/hls/#{session_id}/playlist.m3u8"
        expect(response).to have_http_status(:accepted)
      end
    end
  end

  describe "GET /hls/:id/:segment" do
    let(:session_id) { SecureRandom.hex(16) }
    let!(:session) { create(:hls_session, user: user, session_id: session_id, pid: 99_999) }
    let(:segment_dir) { session.storage_path }

    before do
      FileUtils.mkdir_p(segment_dir)
      File.write(File.join(segment_dir, "playlist.m3u8"), "#EXTM3U\n")
      File.write(File.join(segment_dir, "0.ts"), "dummy_ts_segment_data")
    end

    after do
      FileUtils.rm_rf(segment_dir)
      session.destroy if session.persisted?
    end

    it "returns the segment with correct Content-Type" do
      get "/hls/#{session_id}/0.ts"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("video/mp2t")
    end

    it "works without authentication (iOS media requests don't send cookies)" do
      sign_out user
      get "/hls/#{session_id}/0.ts"
      expect(response).to have_http_status(:ok)
    end

    it "returns 503 for not-yet-produced segment on a live stream" do
      get "/hls/#{session_id}/99.ts"
      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("1")
    end

    it "returns 404 for non-existent segment when ffmpeg has finished" do
      File.write(File.join(segment_dir, "playlist.m3u8"), "#EXTM3U\n#EXT-X-ENDLIST\n")
      get "/hls/#{session_id}/99.ts"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /hls/:id/stop" do
    let(:session_id) { SecureRandom.hex(16) }
    let!(:session) { create(:hls_session, user: user, session_id: session_id, pid: 99_999) }
    let(:segment_dir) { session.storage_path }

    before do
      FileUtils.mkdir_p(segment_dir)
      File.write(File.join(segment_dir, "playlist.m3u8"), "#EXTM3U\n")
    end

    it "returns ok and removes the session" do
      post "/hls/#{session_id}/stop"
      expect(response).to have_http_status(:ok)
      expect(HlsSession.find_by(session_id: session_id)).to be_nil
    end
  end
end
