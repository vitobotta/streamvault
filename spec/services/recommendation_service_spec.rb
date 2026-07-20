require 'rails_helper'

RSpec.describe RecommendationService, type: :service do
  let(:user) { create(:user) }

  around do |ex|
    old_token = ENV["TMDB_READ_ACCESS_TOKEN"]
    ex.run
  ensure
    ENV["TMDB_READ_ACCESS_TOKEN"] = old_token
  end

  describe '.recommendations' do
    it 'returns an empty array when TMDB_READ_ACCESS_TOKEN is blank' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = nil
      result = described_class.recommendations(user)
      expect(result).to be_success
      expect(result.data).to eq([])
    end

    it 'returns an empty array when the user has no watch history' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      result = described_class.recommendations(user)
      expect(result).to be_success
      expect(result.data).to eq([])
    end

    it 'excludes content already in the user library' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      create(:watch_history_entry, user: user, imdb_id: 'tt1375666', show_imdb_id: nil)
      create(:library_entry, user: user, imdb_id: 'tt0468569')

      # Stub TMDB to recommend a movie already in the library
      allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id)
        .with('tt1375666', limit: 5)
        .and_return(ServiceResult.success([
          { tmdb_id: 497, imdb_id: 'tt0468569', title: 'In Library', poster_url: nil, type: 'movie', year: '2008' },
          { tmdb_id: 100, imdb_id: 'tt0000123', title: 'New Rec', poster_url: nil, type: 'movie', year: '2020' }
        ]))

      result = described_class.recommendations(user)
      imdb_ids = result.data.map { |r| r[:imdb_id] }
      expect(imdb_ids).to include('tt0000123')
      expect(imdb_ids).not_to include('tt0468569')
    end

    it 'excludes content already present in watch history' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      create(:watch_history_entry, user: user, imdb_id: 'tt1375666', show_imdb_id: nil)
      create(:watch_history_entry, user: user, imdb_id: 'tt0468569', show_imdb_id: nil)
      allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id)
        .and_return(ServiceResult.success([
          { tmdb_id: 497, imdb_id: 'tt0468569', title: 'Already Watched', poster_url: nil, type: 'movie', year: '2008' },
          { tmdb_id: 100, imdb_id: 'tt0000123', title: 'New Rec', poster_url: nil, type: 'movie', year: '2020' }
        ]))

      imdb_ids = described_class.recommendations(user).data.map { |item| item[:imdb_id] }

      expect(imdb_ids).to include('tt0000123')
      expect(imdb_ids).not_to include('tt0468569')
    end

    it 'uses twenty distinct recent movies and shows as TMDB seeds' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      10.times do |episode|
        create(:watch_history_entry, :episode, user: user,
          imdb_id: 'tt0903747', show_imdb_id: 'tt0903747',
          season_number: 1, episode_number: episode + 1,
          watched_at: episode.minutes.ago)
      end
      20.times do |index|
        create(:watch_history_entry, :movie, user: user,
          imdb_id: "tt#{(index + 1).to_s.rjust(7, '0')}",
          watched_at: (index + 20).minutes.ago)
      end
      calls = []
      allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id) do |_service, imdb_id, limit:|
        calls << [ imdb_id, limit ]
        ServiceResult.success([])
      end

      described_class.recommendations(user)

      expect(calls.length).to eq(20)
      expect(calls.map(&:first).uniq.length).to eq(20)
      expect(calls).to include([ 'tt0903747', 5 ])
      expect(calls.map(&:last).uniq).to eq([ 5 ])
    end

    it 'swallows unexpected errors and returns an empty array' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      create(:watch_history_entry, user: user, imdb_id: 'tt1375666', show_imdb_id: nil)
      allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id)
        .and_raise(StandardError, 'boom')

      result = described_class.recommendations(user)
      expect(result).to be_success
      expect(result.data).to eq([])
    end
  end
end
