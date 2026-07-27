require 'rails_helper'

# Comet's Stremio stream objects carry metadata in `description` and
# `behaviorHints`, NOT in the top-level `title`/`infoHash`/`sources`/`seeders`
# fields that Torrentio uses.  The fixtures below mirror Comet's real response
# shape (captured from a live Comet instance) so the parsing assertions reflect
# what StreamVault actually receives in production.
RSpec.describe CometService do
  let(:rd_api_key) { "test_rd_key_123" }
  let(:service) { described_class.new(rd_api_key: rd_api_key) }

  # A cached (instantly playable) 4K release, as Comet returns it.
  let(:cached_stream) do
    {
      "name" => "[RD⚡] Comet 2160p",
      "description" => "📄 Guardians of the Galaxy (2014) UHD BDRemux 2160p HDR, Dolby Vision [Hybrid].mkv\n📹 DV • HDR\n⭐ BluRay REMUX\n💾 50.4 GB 🔎 DMM",
      "behaviorHints" => {
        "bingeGroup" => "comet|realdebrid|73cc9adbfdcd986f31b013eed1df3ae9786e318d",
        "filename" => "Guardians of the Galaxy (2014) UHD BDRemux 2160p HDR, Dolby Vision [Hybrid].mkv",
        "videoSize" => 54099177569
      },
      "url" => "http://comet.example.com/playback/abc"
    }
  end

  # A download-on-demand (uncached) 1080p release with seeders in the
  # description. Comet marks these with ⬇️ instead of ⚡.
  let(:uncached_stream) do
    {
      "name" => "[RD⬇️] Comet 1080p",
      "description" => "📄 Inception 2010 1080p BluRay x264-YTS.mkv\n📹 x264\n⭐ BluRay\n👤 24 💾 1.8 GB 🔎 Torrents.csv",
      "behaviorHints" => {
        "bingeGroup" => "comet|realdebrid|aca23938c3c9ab14ed2209035521dcab6b22f18f",
        "filename" => "Inception 2010 1080p BluRay x264-YTS.mkv",
        "videoSize" => 1932735283
      },
      "url" => "http://comet.example.com/playback/def"
    }
  end

  around do |ex|
    original_comet = ENV["COMET_URL"]
    ENV["COMET_URL"] = "http://comet.example.com"
    ex.run
    ENV["COMET_URL"] = original_comet
  end

  def stub_streams(imdb_id, type, streams, status: 200)
    path_pattern = type.to_s.in?(%w[show series]) ? "series" : "movie"
    stub_request(:get, %r{comet\.example\.com/[^/]+/stream/#{path_pattern}/#{imdb_id}[^.]*\.json})
      .to_return(
        status: status,
        body: { "streams" => streams }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  describe "#streams" do
    it "returns failure for blank imdb_id" do
      result = service.streams("", "movie")
      expect(result).to be_failure
    end

    it "returns failure when COMET_URL is not configured" do
      ENV["COMET_URL"] = ""
      result = described_class.new(rd_api_key: rd_api_key).streams("tt1375666", "movie")
      expect(result).to be_failure
      expect(result.error_message).to include("not configured")
    end

    it "returns streams for a movie" do
      stub_streams("tt2015381", "movie", [ cached_stream ])

      result = service.streams("tt2015381", "movie")
      expect(result).to be_success
      expect(result.data.length).to eq(1)
      stream = result.data.first
      expect(stream[:info_hash]).to eq("73cc9adbfdcd986f31b013eed1df3ae9786e318d")
      expect(stream[:quality]).to eq("4K")
      expect(stream[:resolve_url]).to eq("http://comet.example.com/playback/abc")
      expect(stream[:filename]).to eq("Guardians of the Galaxy (2014) UHD BDRemux 2160p HDR, Dolby Vision [Hybrid].mkv")
    end

    it "returns streams for a series episode" do
      episode_stream = cached_stream.merge(
        "name" => "[RD⚡] Comet 1080p",
        "behaviorHints" => cached_stream["behaviorHints"].merge(
          "filename" => "Breaking Bad S01E01 720p.mkv"
        )
      )
      stub_streams("tt0903747", "series", [ episode_stream ])

      result = service.streams("tt0903747", "show", season: 1, episode: 1)
      expect(result).to be_success
      expect(result.data.first[:quality]).to eq("1080p")
    end

    it "returns empty array for 404" do
      stub_streams("tt9999999", "movie", [], status: 404)

      result = service.streams("tt9999999", "movie")
      expect(result).to be_success
      expect(result.data).to eq([])
    end

    it "returns failure for non-200 non-404 response" do
      stub_streams("tt1375666", "movie", [], status: 500)

      result = service.streams("tt1375666", "movie")
      expect(result).to be_failure
    end
  end

  # Regression coverage for the Comet metadata parsing fix. Comet puts the
  # real metadata in `description` and `behaviorHints`; these tests ensure
  # each field is extracted correctly rather than falling back to "Unknown"
  # or to Comet's identical "[RD⚡] Comet <res>" name label.
  describe "Comet metadata parsing" do
    it "uses behaviorHints.filename as the title so streams are distinguishable" do
      stub_streams("tt2015381", "movie", [ cached_stream, uncached_stream ])

      streams = service.streams("tt2015381", "movie").data

      expect(streams[0][:title]).to eq("Guardians of the Galaxy (2014) UHD BDRemux 2160p HDR, Dolby Vision [Hybrid].mkv")
      expect(streams[1][:title]).to eq("Inception 2010 1080p BluRay x264-YTS.mkv")
      # Two different releases must produce two distinct titles, never the
      # identical "[RD⚡] Comet 2160p" label Comet uses in `name`.
      expect(streams.map { |s| s[:title] }.uniq.size).to eq(2)
    end

    it "extracts the info hash from behaviorHints.bingeGroup" do
      stub_streams("tt2015381", "movie", [ cached_stream ])

      stream = service.streams("tt2015381", "movie").data.first
      expect(stream[:info_hash]).to eq("73cc9adbfdcd986f31b013eed1df3ae9786e318d")
    end

    it "extracts file size from behaviorHints.videoSize" do
      stub_streams("tt2015381", "movie", [ cached_stream ])

      stream = service.streams("tt2015381", "movie").data.first
      expect(stream[:size]).to eq("50.4 GB")
      expect(stream[:raw_size]).to eq(54099177569)
    end

    it "falls back to parsing size from the description when videoSize is absent" do
      stream_without_videosize = cached_stream.merge("behaviorHints" => cached_stream["behaviorHints"].except("videoSize"))
      stub_streams("tt2015381", "movie", [ stream_without_videosize ])

      stream = service.streams("tt2015381", "movie").data.first
      expect(stream[:size]).to eq("50.4 GB")
    end

    it "marks cached (⚡) streams as rd_plus for cached-first sorting" do
      stub_streams("tt2015381", "movie", [ cached_stream, uncached_stream ])

      streams = service.streams("tt2015381", "movie").data
      cached = streams.find { |s| s[:title].include?("Guardians") }
      on_demand = streams.find { |s| s[:title].include?("Inception") }
      expect(cached[:rd_plus]).to be true
      expect(on_demand[:rd_plus]).to be false
    end

    it "extracts seeders from the 👤 marker in the description" do
      stub_streams("tt2015381", "movie", [ uncached_stream ])

      stream = service.streams("tt2015381", "movie").data.first
      expect(stream[:seeders]).to eq(24)
    end

    it "reports zero seeders when none are present" do
      stub_streams("tt2015381", "movie", [ cached_stream ])

      stream = service.streams("tt2015381", "movie").data.first
      expect(stream[:seeders]).to eq(0)
    end

    it "detects quality from the release name" do
      stub_streams("tt2015381", "movie", [ cached_stream, uncached_stream ])

      streams = service.streams("tt2015381", "movie").data
      expect(streams[0][:quality]).to eq("4K")
      expect(streams[1][:quality]).to eq("1080p")
    end
  end

  describe ".resolve_base_url" do
    it "returns the configured COMET_URL" do
      ENV["COMET_URL"] = "http://my-comet:8000"
      expect(described_class.resolve_base_url).to eq("http://my-comet:8000")
    end
  end

  # Regression coverage for the padded-base64 fix. Comet's config-path parser
  # rejects unpadded base64 and silently serves a placeholder stream, so the
  # config segment must be standard padded base64 (length divisible by 4).
  describe "config encoding" do
    it "encodes the debrid config as padded base64" do
      captured_config = nil
      stub_request(:get, %r{comet\.example\.com/([^/]+)/stream/movie/tt1375666\.json})
        .to_return do |request|
          uri = request.uri
          path = uri.respond_to?(:path) ? uri.path : URI.parse(uri).path
          captured_config = path.split("/")[1]
          { status: 200, body: { "streams" => [] }.to_json, headers: { "Content-Type" => "application/json" } }
        end

      service.streams("tt1375666", "movie")

      expect(captured_config).to be_present
      # Padded base64 always has a length that is a multiple of 4; unpadded
      # base64 (the bug) does not, and Comet cannot decode it.
      expect(captured_config.length % 4).to eq(0)
      # It must still round-trip to the expected debrid config.
      config = JSON.parse(Base64.urlsafe_decode64(captured_config))
      expect(config["debridService"]).to eq("realdebrid")
      expect(config["debridApiKey"]).to eq(rd_api_key)
    end

    it "omits the config segment when no RD key is provided" do
      stub_request(:get, %r{comet\.example\.com/stream/movie/tt1375666\.json})

      described_class.new(rd_api_key: nil).streams("tt1375666", "movie")

      expect(WebMock).to have_requested(:get, %r{comet\.example\.com/stream/movie/tt1375666\.json})
        .at_least_once
      expect(WebMock).not_to have_requested(:get, %r{comet\.example\.com/[^/]+/stream/movie/tt1375666\.json})
    end
  end
end

RSpec.describe StreamProvider do
  around do |ex|
    original_provider = ENV["STREAM_PROVIDER"]
    original_comet = ENV["COMET_URL"]
    ex.run
    ENV["STREAM_PROVIDER"] = original_provider
    ENV["COMET_URL"] = original_comet
  end

  describe ".providers" do
    it "returns only Torrentio by default" do
      ENV["STREAM_PROVIDER"] = "torrentio"
      ENV["COMET_URL"] = ""
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(Streams::TorrentioProvider)
    end

    it "returns Comet then Torrentio when STREAM_PROVIDER=comet" do
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "http://comet:8000"
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(2)
      expect(providers.first).to be_a(CometService)
      expect(providers.last).to be_a(Streams::TorrentioProvider)
    end

    it "returns Comet then Torrentio when STREAM_PROVIDER=auto and COMET_URL set" do
      ENV["STREAM_PROVIDER"] = "auto"
      ENV["COMET_URL"] = "http://comet:8000"
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(2)
      expect(providers.first).to be_a(CometService)
    end

    it "returns only Torrentio when STREAM_PROVIDER=auto and COMET_URL blank" do
      ENV["STREAM_PROVIDER"] = "auto"
      ENV["COMET_URL"] = ""
      providers = described_class.providers(rd_api_key: "key")
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(Streams::TorrentioProvider)
    end
  end

  describe ".resolve_base_urls" do
    it "includes Comet URL when configured" do
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "http://my-comet:8000"
      urls = described_class.resolve_base_urls
      expect(urls).to include("http://my-comet:8000")
      expect(urls).to include("https://torrentio.strem.fun")
    end

    it "returns only torrentio URLs when Comet not configured" do
      ENV["STREAM_PROVIDER"] = "torrentio"
      ENV["COMET_URL"] = ""
      urls = described_class.resolve_base_urls
      expect(urls).to include("https://torrentio.strem.fun")
      expect(urls.any? { |u| u.include?("comet") }).to be false
    end
  end
end
