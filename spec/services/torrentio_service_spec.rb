require 'rails_helper'

RSpec.describe TorrentioService do
  subject(:service) { described_class.new }

  describe "#search" do
    it "returns failure for blank query" do
      result = service.search("")
      expect(result).to be_failure
      expect(result.error_message).to eq("Query cannot be blank")
    end

    it "returns search results from Cinemeta" do
      # Stub Cinemeta movie search
      stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
        .to_return(
          status: 200,
          body: {
            "metas" => [
              { "id" => "tt1375666", "imdb_id" => "tt1375666", "name" => "Inception", "releaseInfo" => "2010", "poster" => "https://example.com/poster.jpg" }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      # Stub Cinemeta series search
      stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
        .to_return(status: 200, body: { "metas" => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = service.search("Inception")
      expect(result).to be_success
      expect(result.data).to be_an(Array)
      expect(result.data.first[:imdb_id]).to eq("tt1375666")
      expect(result.data.first[:title]).to eq("Inception")
    end

    it "handles Cinemeta timeout gracefully" do
      stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/.*\.json})
        .to_timeout

      result = service.search("test")
      expect(result).to be_success
      expect(result.data).to eq([])
    end
  end

  describe "#streams" do
    it "returns failure for blank imdb_id" do
      result = service.streams("", "movie")
      expect(result).to be_failure
    end

    it "returns streams for a movie" do
      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
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

    it "filters to preferred languages and sorts the default language first" do
      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt1375666\.json})
        .to_return(
          status: 200,
          body: {
            "streams" => [
              { "title" => "Inception ENG 2160p", "url" => "https://torrentio.strem.fun/resolve/eng" },
              { "title" => "Inception FRENCH 1080p", "url" => "https://torrentio.strem.fun/resolve/french" },
              { "title" => "Inception GERMAN 1080p", "url" => "https://torrentio.strem.fun/resolve/german" },
              { "title" => "Inception 720p", "url" => "https://torrentio.strem.fun/resolve/unknown" }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.streams(
        "tt1375666",
        "movie",
        preferred_languages: %w[ENG FRENCH],
        default_language: "FRENCH"
      )

      expect(result).to be_success
      expect(result.data.map { |stream| stream[:resolve_url] }).to eq([
        "https://torrentio.strem.fun/resolve/french",
        "https://torrentio.strem.fun/resolve/eng",
        "https://torrentio.strem.fun/resolve/unknown"
      ])
      expect(result.data.map { |stream| stream[:language_score] }).to eq([ 0, 1, 1 ])
    end

    it "returns streams for a series episode" do
      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/series/tt0903747:1:1\.json})
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
      stub_request(:get, %r{torrentio\.strem\.fun/([^/]+/)?stream/movie/tt9999999\.json})
        .to_return(status: 404, body: "Not Found")

      result = service.streams("tt9999999", "movie")
      expect(result).to be_success
      expect(result.data).to eq([])
    end
  end

  describe "#metadata" do
    it "returns metadata from Cinemeta" do
      stub_request(:get, "https://v3-cinemeta.strem.io/meta/movie/tt1375666.json")
        .to_return(
          status: 200,
          body: {
            "meta" => {
              "id" => "tt1375666",
              "imdb_id" => "tt1375666",
              "name" => "Inception",
              "year" => "2010",
              "poster" => "https://example.com/poster.jpg",
              "description" => "A thief who steals corporate secrets...",
              "genres" => [ "Action", "Sci-Fi" ],
              "director" => [ "Christopher Nolan" ],
              "cast" => [ "Leonardo DiCaprio", "Joseph Gordon-Levitt" ],
              "imdbRating" => "8.8",
              "runtime" => "148 min"
            }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.metadata("tt1375666", "movie")
      expect(result).to be_success
      expect(result.data[:title]).to eq("Inception")
      expect(result.data[:imdb_rating]).to eq("8.8")
      expect(result.data[:genre]).to eq("Action, Sci-Fi")
      expect(result.data[:runtime_seconds]).to eq(8880)
    end

    it "returns show metadata with episodes" do
      stub_request(:get, "https://v3-cinemeta.strem.io/meta/series/tt0903747.json")
        .to_return(
          status: 200,
          body: {
            "meta" => {
              "id" => "tt0903747",
              "imdb_id" => "tt0903747",
              "name" => "Breaking Bad",
              "year" => "2008–2013",
              "poster" => "https://example.com/poster.jpg",
              "description" => "A high school chemistry teacher...",
              "genres" => [ "Crime", "Drama" ],
              "imdbRating" => "9.5",
              "videos" => [
                { "season" => 1, "episode" => 1, "name" => "Pilot", "released" => "2008-01-20", "runtime" => "58 min" },
                { "season" => 1, "episode" => 2, "name" => "Cat's in the Bag...", "released" => "2008-01-27", "runtime" => "PT48M" },
                { "season" => 2, "episode" => 1, "name" => "Seven Thirty-Seven", "released" => "2009-03-08" }
              ]
            }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = service.metadata("tt0903747", "show")
      expect(result).to be_success
      expect(result.data[:title]).to eq("Breaking Bad")
      expect(result.data[:episodes].length).to eq(3)
      expect(result.data[:total_seasons]).to eq(2)
      expect(result.data[:episodes].first[:title]).to eq("Pilot")
      expect(result.data[:episodes].first[:runtime_seconds]).to eq(3480)
      expect(result.data[:episodes].second[:runtime_seconds]).to eq(2880)
    end
  end
end
