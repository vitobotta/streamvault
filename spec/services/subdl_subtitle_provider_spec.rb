require 'rails_helper'

RSpec.describe SubdlSubtitleProvider do
  describe "#search" do
    it "normalizes unpacked SubDL subtitle files into external tracks" do
      search_connection = instance_double(Faraday::Connection)
      request = instance_double(Faraday::Request, headers: {})
      response = instance_double(
        Faraday::Response,
        success?: true,
        body: {
          "results" => [
            {
              "n_id" => "subtitle-123",
              "language" => "en",
              "format" => "srt",
              "release_name" => "Inception.2010.1080p",
              "unpack_files" => [
                {
                  "n_id" => "subtitle-123",
                  "language" => "en",
                  "format" => "srt",
                  "release_name" => "Inception.2010.1080p",
                  "hi" => false
                },
                {
                  "language" => "en",
                  "format" => "zip",
                  "n_id" => "subtitle-zip"
                }
              ]
            }
          ]
        }
      )
      expect(search_connection).to receive(:get).with(
        "api/v2/subtitles/search",
        hash_including(
          imdb_id: "tt1375666",
          type: "movie",
          languages: "en",
          unpack: "1"
        )
      ).and_yield(request).and_return(response)

      provider = described_class.new(api_key: "subdl-key", search_connection: search_connection)

      tracks = provider.search(
        imdb_id: "tt1375666",
        type: "movie",
        title: "Inception",
        filename: "Inception.2010.1080p.mkv",
        preferred_languages: [ "ENG" ],
        default_language: "ENG"
      )

      expect(tracks.length).to eq(1)
      expect(tracks.first).to include(
        language: "ENG",
        language_label: "English",
        codec: "srt",
        external: true,
        source: "subdl",
        download_path: "/api/v2/subtitles/subtitle-123/download?format=file"
      )
      expect(request.headers["Authorization"]).to eq("Bearer subdl-key")
      expect(tracks.first[:index]).to start_with("external:subdl:")
      expect(tracks.first[:label]).to include("SubDL")
    end

    it "does not search without an API key" do
      search_connection = instance_double(Faraday::Connection)
      allow(Rails.logger).to receive(:info)
      expect(search_connection).not_to receive(:get)

      provider = described_class.new(api_key: "", search_connection: search_connection)

      expect(provider.search(imdb_id: "tt1375666", type: "movie")).to eq([])
      expect(Rails.logger).to have_received(:info).with("[SubDL] subtitle search disabled: SUBDL_API_KEY is not configured")
    end
  end

  describe "#download" do
    it "downloads only whitelisted SubDL subtitle paths" do
      download_connection = instance_double(Faraday::Connection)
      request = instance_double(Faraday::Request, headers: {})
      response = instance_double(Faraday::Response, success?: true, body: "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
      expect(download_connection).to receive(:get)
        .with("/api/v2/subtitles/subtitle-123/download?format=file")
        .and_yield(request)
        .and_return(response)

      provider = described_class.new(api_key: "subdl-key", download_connection: download_connection)

      result = provider.download("/api/v2/subtitles/subtitle-123/download?format=file")

      expect(result).to be_success
      expect(result.data).to include("Hello")
      expect(request.headers["Authorization"]).to eq("Bearer subdl-key")
    end

    it "rejects arbitrary external download URLs" do
      download_connection = instance_double(Faraday::Connection)
      expect(download_connection).not_to receive(:get)

      provider = described_class.new(api_key: "subdl-key", download_connection: download_connection)

      result = provider.download("https://example.test/subtitle/123/456")

      expect(result).to be_failure
      expect(result.error_message).to eq("Invalid subtitle download path")
    end
  end
end
