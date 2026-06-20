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

  describe "DELETE /watch_history/:id" do
    before { sign_in user }

    context "with multiple progress entries for the same movie" do
      # ProgressTrackingService writes a new row every 5 seconds, so a single
      # watch session produces many entries with the same imdb_id.
      let!(:entries) do
        3.times.map do |i|
          create(:watch_history_entry, :movie, user: user, imdb_id: "tt1375666",
                 title: "Inception", watched_at: i.minutes.ago)
        end
      end

      it "removes ALL entries for that content, not just the latest" do
        latest = entries.max_by(&:watched_at)
        expect {
          delete watch_history_path(latest), headers: { "HTTP_REFERER" => root_path }
        }.to change(WatchHistoryEntry, :count).by(-3)

        expect(user.watch_history_entries.where(imdb_id: "tt1375666")).to be_empty
        expect(response).to redirect_to(root_path)
      end
    end

    context "with multiple episodes of the same show" do
      let!(:ep1) do
        create(:watch_history_entry, :episode, user: user, imdb_id: "tt0903747",
               show_imdb_id: "tt0903747", season_number: 1, episode_number: 1, watched_at: 2.hours.ago)
      end
      let!(:ep2) do
        create(:watch_history_entry, :episode, user: user, imdb_id: "tt0903747",
               show_imdb_id: "tt0903747", season_number: 1, episode_number: 2, watched_at: 1.hour.ago)
      end
      let!(:other_show) do
        create(:watch_history_entry, :episode, user: user, imdb_id: "tt0944947",
               show_imdb_id: "tt0944947", season_number: 1, episode_number: 1, watched_at: 30.minutes.ago)
      end

      it "removes all episodes for that show but leaves other shows" do
        expect {
          delete watch_history_path(ep2)
        }.to change(WatchHistoryEntry, :count).by(-2)

        expect(user.watch_history_entries.where(show_imdb_id: "tt0903747")).to be_empty
        expect(user.watch_history_entries.find(other_show.id)).to eq(other_show)
      end
    end

    context "when the entry belongs to another user" do
      let(:other_user) { create(:user) }
      let!(:own_entry) { create(:watch_history_entry, user: user, imdb_id: "tt1375666") }
      let!(:other_entry) { create(:watch_history_entry, user: other_user, imdb_id: "tt1375666") }

      it "does not delete other users' entries" do
        expect {
          delete watch_history_path(own_entry)
        }.not_to change { other_entry.reload.attributes }

        expect(user.watch_history_entries.where(imdb_id: "tt1375666")).to be_empty
        expect(other_user.watch_history_entries.where(imdb_id: "tt1375666")).to exist
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
