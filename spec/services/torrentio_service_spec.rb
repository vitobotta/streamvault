require 'rails_helper'

RSpec.describe TorrentioService do
  subject(:service) { described_class.new }

  describe "#search" do
    it "returns failure for blank query" do
      result = service.search("")
      expect(result).to be_failure
      expect(result.error_message).to eq("Query cannot be blank")
    end

    it "returns search results from OMDB" do
      # Stub OMDB search
      stub_request(:get, "https://www.omdbapi.com/")
        .with(query: hash_including(s: "Inception"))
        .to_return(
          status: 200,
          body: {
            "Search" => [
              { "imdbID" => "tt1375666", "Title" => "Inception", "Year" => "2010", "Type" => "movie", "Poster" => "https://example.com/poster.jpg" }
            ],
            "Response" => "True"
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      # Stub Torrentio streams
      stub_request(:get, %r{torrentio\.strem\.fun/stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: { "streams" => [{ "title" => "Inception 1080p", "infoHash" => "abc123" }] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.search("Inception")
      expect(result).to be_success
      expect(result.data).to be_an(Array)
      expect(result.data.first[:imdb_id]).to eq("tt1375666")
    end
  end

  describe "#streams" do
    it "returns failure for blank imdb_id" do
      result = service.streams("", "movie")
      expect(result).to be_failure
    end

    it "returns streams for a movie" do
      stub_request(:get, %r{torrentio\.strem\.fun/stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception 1080p [YTS]", "infoHash" => "abc123def", "fileIdx" => 0, "seeders" => 100, "size" => 1_500_000_000 }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.streams("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data.length).to eq(1)
      expect(result.data.first[:info_hash]).to eq("abc123def")
      expect(result.data.first[:quality]).to eq("1080p")
    end

    it "returns streams for a series episode" do
      stub_request(:get, %r{torrentio\.strem\.fun/stream/series/tt0903747:1:1\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Breaking Bad S01E01 720p", "infoHash" => "xyz789", "fileIdx" => 0, "seeders" => 50 }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.streams("tt0903747", "show", season: 1, episode: 1)
      expect(result).to be_success
      expect(result.data.first[:quality]).to eq("720p")
    end

    it "returns empty array for 404" do
      stub_request(:get, %r{torrentio\.strem\.fun/stream/movie/tt9999999\.json})
        .to_return(status: 404, body: "Not Found")

      result = service.streams("tt9999999", "movie")
      expect(result).to be_success
      expect(result.data).to eq([])
    end
  end

  describe "#metadata" do
    it "returns metadata from OMDB" do
      stub_request(:get, "https://www.omdbapi.com/")
        .with(query: hash_including(i: "tt1375666"))
        .to_return(
          status: 200,
          body: {
            "Response" => "True",
            "imdbID" => "tt1375666",
            "Title" => "Inception",
            "Year" => "2010",
            "Type" => "movie",
            "Poster" => "https://example.com/poster.jpg",
            "Plot" => "A thief who steals corporate secrets...",
            "Genre" => "Action, Sci-Fi",
            "Director" => "Christopher Nolan",
            "Actors" => "Leonardo DiCaprio, Joseph Gordon-Levitt",
            "Rated" => "PG-13",
            "imdbRating" => "8.8"
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.metadata("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:title]).to eq("Inception")
      expect(result.data[:imdb_rating]).to eq("8.8")
    end
  end
end
