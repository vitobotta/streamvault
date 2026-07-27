require "rails_helper"

RSpec.describe PlaybackDescriptor do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:issued_at) { Time.zone.local(2026, 7, 27, 12, 0, 0) }

  def issue_descriptor
    source_token = ResolvedSource.issue(
      user: user,
      url: "https://download.real-debrid.com/d/file123/video.mp4",
      filename: "video.mp4"
    )
    described_class.issue(
      user: user,
      source_token: source_token,
      filename: "video.mp4",
      content_ref: ContentRef.new(imdb_id: "tt1375666", type: "movie")
    )
  end

  it "remains refreshable for the lifetime of its nested source token" do
    token = travel_to(issued_at) { issue_descriptor }

    travel_to(issued_at + ResolvedSource::TOKEN_TTL - 1.minute) do
      descriptor = described_class.resolve(token: token, user: user)
      expect(descriptor.filename).to eq("video.mp4")
    end
  end

  it "expires with the nested source token" do
    token = travel_to(issued_at) { issue_descriptor }

    travel_to(issued_at + ResolvedSource::TOKEN_TTL + 1.second) do
      expect {
        described_class.resolve(token: token, user: user)
      }.to raise_error(ApplicationToken::Invalid)
    end
  end
end
