# frozen_string_literal: true

require "rails_helper"

RSpec.describe ParentalControls::RatingResolver do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:omdb) { instance_double(Catalog::OmdbClient, configured?: true) }
  let(:tmdb) { nil }

  def resolver_with(omdb: self.omdb, tmdb: self.tmdb)
    described_class.new(omdb: omdb, tmdb: tmdb, cache: cache)
  end

  describe "#min_age" do
    it "resolves the age from the OMDB certification" do
      allow(omdb).to receive(:ratings).with("tt1375666").and_return({ rated: "PG-13" })

      expect(resolver_with.min_age("tt1375666")).to eq(13)
    end

    it "falls back to TMDB when OMDB has no certification" do
      tmdb_service = instance_double(TmdbService)
      allow(omdb).to receive(:ratings).and_return({})
      allow(tmdb_service).to receive(:certification_for_imdb_id).with("tt0903747").and_return("TV-MA")

      expect(resolver_with(tmdb: tmdb_service).min_age("tt0903747")).to eq(17)
    end

    it "uses the TMDB certification when OMDB is not configured" do
      unconfigured = instance_double(Catalog::OmdbClient, configured?: false)
      tmdb_service = instance_double(TmdbService)
      expect(unconfigured).not_to receive(:ratings)
      allow(tmdb_service).to receive(:certification_for_imdb_id).with("tt1375666").and_return("R")

      expect(resolver_with(omdb: unconfigured, tmdb: tmdb_service).min_age("tt1375666")).to eq(17)
    end

    it "fails closed for unrated titles" do
      tmdb_service = instance_double(TmdbService)
      allow(omdb).to receive(:ratings).and_return({ rated: "N/A" })
      allow(tmdb_service).to receive(:certification_for_imdb_id).and_return(nil)

      expect(resolver_with(tmdb: tmdb_service).min_age("tt0000001")).to eq(ParentalControls::Rating::UNKNOWN_AGE)
    end

    it "fails closed for titles that only carry a censorship seal" do
      tmdb_service = instance_double(TmdbService)
      allow(omdb).to receive(:ratings).and_return({ rated: "Passed" })
      allow(tmdb_service).to receive(:certification_for_imdb_id).and_return(nil)

      expect(resolver_with(tmdb: tmdb_service).min_age("tt0021814")).to eq(ParentalControls::Rating::UNKNOWN_AGE)
    end

    it "fails closed when every source errors" do
      tmdb_service = instance_double(TmdbService)
      allow(omdb).to receive(:ratings).and_raise(StandardError, "boom")
      allow(tmdb_service).to receive(:certification_for_imdb_id).and_raise(StandardError, "boom")

      expect(resolver_with(tmdb: tmdb_service).min_age("tt0000002")).to eq(ParentalControls::Rating::UNKNOWN_AGE)
    end

    it "fails closed when no rating source is available" do
      expect(resolver_with(omdb: instance_double(Catalog::OmdbClient, configured?: false)).min_age("tt0000003"))
        .to eq(ParentalControls::Rating::UNKNOWN_AGE)
    end

    it "returns the unknown age for blank IDs without any lookups" do
      expect(omdb).not_to receive(:ratings)

      expect(resolver_with.min_age(nil)).to eq(ParentalControls::Rating::UNKNOWN_AGE)
      expect(resolver_with.min_age("")).to eq(ParentalControls::Rating::UNKNOWN_AGE)
    end

    it "caches the resolved age per IMDb ID" do
      expect(omdb).to receive(:ratings).once.with("tt1375666").and_return({ rated: "PG" })

      resolver = resolver_with
      expect(resolver.min_age("tt1375666")).to eq(8)
      expect(resolver.min_age("tt1375666")).to eq(8)
    end

    it "caches unknown results too" do
      tmdb_service = instance_double(TmdbService)
      allow(omdb).to receive(:ratings).once.and_return({})
      expect(tmdb_service).to receive(:certification_for_imdb_id).once.and_return(nil)

      resolver = resolver_with(tmdb: tmdb_service)
      expect(resolver.min_age("tt0000004")).to eq(ParentalControls::Rating::UNKNOWN_AGE)
      expect(resolver.min_age("tt0000004")).to eq(ParentalControls::Rating::UNKNOWN_AGE)
    end
  end

  describe ".sources_configured?" do
    around do |example|
      previous = { "OMDB_API_KEY" => ENV["OMDB_API_KEY"], "TMDB_READ_ACCESS_TOKEN" => ENV["TMDB_READ_ACCESS_TOKEN"] }
      example.run
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    it "is true when OMDB is configured" do
      ENV["OMDB_API_KEY"] = "spec-omdb-#{SecureRandom.hex(4)}"
      ENV.delete("TMDB_READ_ACCESS_TOKEN")

      expect(described_class.sources_configured?).to be(true)
    end

    it "is true when only TMDB is configured" do
      ENV.delete("OMDB_API_KEY")
      ENV["TMDB_READ_ACCESS_TOKEN"] = "spec-tmdb-#{SecureRandom.hex(4)}"

      expect(described_class.sources_configured?).to be(true)
    end

    it "is false when neither source is configured" do
      ENV.delete("OMDB_API_KEY")
      ENV.delete("TMDB_READ_ACCESS_TOKEN")

      expect(described_class.sources_configured?).to be(false)
    end

    it "is false when a TMDB token is present but the service cannot be built" do
      ENV.delete("OMDB_API_KEY")
      ENV["TMDB_READ_ACCESS_TOKEN"] = "spec-broken-#{SecureRandom.hex(4)}"
      allow(TmdbService).to receive(:new).and_raise(StandardError, "bad token")

      expect(described_class.sources_configured?).to be(false)
    end
  end

  describe "default construction" do
    around do |example|
      old_token = ENV["TMDB_READ_ACCESS_TOKEN"]
      example.run
    ensure
      ENV["TMDB_READ_ACCESS_TOKEN"] = old_token
    end

    it "builds a TMDB service only when the access token is configured" do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test-token"
      expect(TmdbService).to receive(:new).and_return(instance_double(TmdbService))
      described_class.new(omdb: omdb, cache: cache)
    end

    it "skips TMDB entirely when the access token is missing" do
      ENV["TMDB_READ_ACCESS_TOKEN"] = nil
      expect(TmdbService).not_to receive(:new)
      described_class.new(omdb: omdb, cache: cache)
    end
  end
end
