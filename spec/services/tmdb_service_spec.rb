require 'rails_helper'

RSpec.describe TmdbService, type: :service do
  let(:token) { 'test_tmdb_token' }
  let(:service) { described_class.new }

  around do |ex|
    old_token = ENV["TMDB_READ_ACCESS_TOKEN"]
    ENV["TMDB_READ_ACCESS_TOKEN"] = token
    ex.run
  ensure
    ENV["TMDB_READ_ACCESS_TOKEN"] = old_token
  end

  describe '#recommendations_for_imdb_id' do
    it 'returns failure when imdb_id is blank' do
      result = service.recommendations_for_imdb_id(nil)
      expect(result).to be_failure
      expect(result.error_message).to eq('IMDb ID required')
    end

    it 'returns failure when TMDB find returns nothing' do
      stub_request(:get, %r{api\.themoviedb\.org/3/find/})
        .to_return(status: 200, body: { "movie_results" => [], "tv_results" => [] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      result = service.recommendations_for_imdb_id('tt0000001')
      expect(result).to be_failure
      expect(result.error_message).to eq('Not found on TMDB')
    end

    it 'returns recommendations for a movie' do
      # /find → movie
      stub_request(:get, %r{api\.themoviedb\.org/3/find/tt1375666})
        .to_return(status: 200, body: {
          "movie_results" => [ { "id" => 27205, "title" => "Inception" } ],
          "tv_results" => []
        }.to_json, headers: { 'Content-Type' => 'application/json' })

      # /movie/{id}/recommendations
      stub_request(:get, %r{api\.themoviedb\.org/3/movie/27205/recommendations})
        .to_return(status: 200, body: {
          "results" => [ { "id" => 497, "title" => "The Dark Knight", "poster_path" => "/qJ2tW6WMUDux911pr6c6I0wQpbM.jpg", "release_date" => "2008-07-16" } ]
        }.to_json, headers: { 'Content-Type' => 'application/json' })

      # /movie/{id}/external_ids
      stub_request(:get, %r{api\.themoviedb\.org/3/movie/497/external_ids})
        .to_return(status: 200, body: { "imdb_id" => "tt0468569" }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      result = service.recommendations_for_imdb_id('tt1375666')
      expect(result).to be_success
      expect(result.data.length).to eq(1)
      rec = result.data.first
      expect(rec[:tmdb_id]).to eq(497)
      expect(rec[:imdb_id]).to eq('tt0468569')
      expect(rec[:title]).to eq('The Dark Knight')
      expect(rec[:type]).to eq('movie')
      expect(rec[:year]).to eq('2008')
    end

    it 'skips recommendations with no IMDb ID' do
      stub_request(:get, %r{api\.themoviedb\.org/3/find/tt1375666})
        .to_return(status: 200, body: {
          "movie_results" => [ { "id" => 27205, "title" => "Inception" } ],
          "tv_results" => []
        }.to_json, headers: { 'Content-Type' => 'application/json' })

      stub_request(:get, %r{api\.themoviedb\.org/3/movie/27205/recommendations})
        .to_return(status: 200, body: {
          "results" => [ { "id" => 497, "title" => "The Dark Knight", "release_date" => "2008-07-16" } ]
        }.to_json, headers: { 'Content-Type' => 'application/json' })

      stub_request(:get, %r{api\.themoviedb\.org/3/movie/497/external_ids})
        .to_return(status: 200, body: { "imdb_id" => nil }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      result = service.recommendations_for_imdb_id('tt1375666')
      expect(result).to be_success
      expect(result.data).to be_empty
    end

    it 'resolves only the requested number of recommendation candidates' do
      stub_request(:get, %r{api\.themoviedb\.org/3/find/tt1375666})
        .to_return(status: 200, body: {
          "movie_results" => [ { "id" => 27205, "title" => "Inception" } ],
          "tv_results" => []
        }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, %r{api\.themoviedb\.org/3/movie/27205/recommendations})
        .to_return(status: 200, body: {
          "results" => [
            { "id" => 497, "title" => "The Dark Knight" },
            { "id" => 498, "title" => "Should Not Resolve" }
          ]
        }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, %r{api\.themoviedb\.org/3/movie/497/external_ids})
        .to_return(status: 200, body: { "imdb_id" => "tt0468569" }.to_json,
          headers: { 'Content-Type' => 'application/json' })

      result = service.recommendations_for_imdb_id('tt1375666', limit: 1)

      expect(result.data.map { |item| item[:tmdb_id] }).to eq([ 497 ])
      expect(a_request(:get, %r{api\.themoviedb\.org/3/movie/498/external_ids}))
        .not_to have_been_made
    end
  end
end
