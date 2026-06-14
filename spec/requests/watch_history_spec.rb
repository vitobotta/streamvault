require 'rails_helper'

RSpec.describe "WatchHistory", type: :request do
  let(:user) { create(:user) }

  describe "GET /watch_history" do
    context "when not authenticated" do
      it "redirects to login" do
        get watch_history_index_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get watch_history_index_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "DELETE /watch_history/clear_all" do
    before do
      sign_in user
      create(:watch_history_entry, user: user)
      create(:episode_progress, user: user)
    end

    it "clears all history" do
      expect {
        delete clear_all_watch_history_index_path
      }.to change(WatchHistoryEntry, :count).by(-1).and change(EpisodeProgress, :count).by(-1)

      expect(response).to redirect_to(watch_history_index_path)
    end
  end
end
