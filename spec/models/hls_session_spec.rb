require 'rails_helper'

RSpec.describe HlsSession, type: :model do
  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:session_id) }

  it "enforces unique session IDs" do
    user = create(:user)
    create(:hls_session, user: user, session_id: "a" * 32)

    expect(build(:hls_session, user: user, session_id: "a" * 32)).not_to be_valid
  end

  it "rejects session IDs that could escape the HLS root" do
    expect(build(:hls_session, session_id: "../outside")).not_to be_valid
  end

  it "derives storage paths from the database ID" do
    session = create(:hls_session)

    expect(session.storage_path).to eq(HlsSession::HLS_ROOT.join(session.id.to_s))
    expect(session.playlist_path).to eq(session.storage_path.join("playlist.m3u8"))
    expect(session.segment_path(4)).to eq(session.storage_path.join("4.ts"))
    expect { session.segment_path("../4") }.to raise_error(ArgumentError)
  end
end
