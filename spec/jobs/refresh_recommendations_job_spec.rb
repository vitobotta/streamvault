require 'rails_helper'

RSpec.describe RefreshRecommendationsJob, type: :job do
  let(:user) { create(:user) }

  around do |ex|
    old_token = ENV["TMDB_READ_ACCESS_TOKEN"]
    ex.run
  ensure
    ENV["TMDB_READ_ACCESS_TOKEN"] = old_token
  end

  describe "#perform" do
    it "does nothing when the user does not exist" do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      expect(RecommendationService).not_to receive(:refresh)

      described_class.perform_now(999_999)
    end

    it "does nothing when TMDB is not configured" do
      ENV["TMDB_READ_ACCESS_TOKEN"] = nil
      expect(RecommendationService).not_to receive(:refresh)

      described_class.perform_now(user.id)
    end

    it "refreshes the user's cache" do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      allow(RecommendationService).to receive(:refresh).with(user)

      described_class.perform_now(user.id)

      expect(RecommendationService).to have_received(:refresh).with(user)
    end

    it "contains unexpected provider errors" do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      allow(RecommendationService).to receive(:refresh).and_raise(StandardError, "boom")

      expect { described_class.perform_now(user.id) }.not_to raise_error
    end
  end

  describe '.enqueue_debounced' do
    it 'enqueues a job when no lock is held' do
      allow(Rails.cache).to receive(:write)
        .with(anything, true, hash_including(unless_exist: true))
        .and_return(true)

      expect {
        described_class.enqueue_debounced(user.id)
      }.to have_enqueued_job(described_class).with(user.id)
    end

    it 'does not enqueue a duplicate when the lock is already held' do
      allow(Rails.cache).to receive(:write)
        .with(anything, true, hash_including(unless_exist: true))
        .and_return(false)

      expect {
        described_class.enqueue_debounced(user.id)
      }.not_to have_enqueued_job(described_class)
    end
  end
end
