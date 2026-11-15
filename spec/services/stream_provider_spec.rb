require 'rails_helper'

RSpec.describe StreamProvider, type: :service do
  around do |ex|
    previous = {
      "STREAM_PROVIDER" => ENV["STREAM_PROVIDER"],
      "COMET_URL" => ENV["COMET_URL"],
      "AIOSTREAMS_URL" => ENV["AIOSTREAMS_URL"]
    }
    ex.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  describe '.providers' do
    it 'returns only Torrentio by default' do
      ENV["STREAM_PROVIDER"] = nil
      providers = described_class.providers(rd_api_key: 'test_key')
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(Streams::TorrentioProvider)
    end

    it 'returns only Torrentio when explicitly set' do
      ENV["STREAM_PROVIDER"] = "torrentio"
      providers = described_class.providers(rd_api_key: 'test_key')
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(Streams::TorrentioProvider)
    end

    it 'returns Comet + Torrentio when set to comet' do
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "https://comet.example.com"

      providers = described_class.providers(rd_api_key: 'test_key')
      expect(providers.length).to eq(2)
      expect(providers.first).to be_a(CometService)
      expect(providers.last).to be_a(Streams::TorrentioProvider)
    end

    it 'falls back to Torrentio when auto and Comet is not configured' do
      ENV["STREAM_PROVIDER"] = "auto"
      ENV["COMET_URL"] = nil
      ENV["AIOSTREAMS_URL"] = nil

      providers = described_class.providers(rd_api_key: 'test_key')
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(Streams::TorrentioProvider)
    end

    it 'returns AIOStreams + Torrentio when set to aiostreams' do
      ENV["STREAM_PROVIDER"] = "aiostreams"
      ENV["AIOSTREAMS_URL"] = "https://aiostreams.example.com/stremio/uuid/manifest.json"

      providers = described_class.providers(rd_api_key: 'test_key')

      expect(providers.first).to be_a(Streams::AioStreamsProvider)
      expect(providers.last).to be_a(Streams::TorrentioProvider)
    end

    it 'puts AIOStreams first in auto mode when configured' do
      ENV["STREAM_PROVIDER"] = "auto"
      ENV["AIOSTREAMS_URL"] = "https://aiostreams.example.com/stremio/uuid"
      ENV["COMET_URL"] = "https://comet.example.com"

      providers = described_class.providers(rd_api_key: 'test_key')

      expect(providers.map(&:class)).to eq([ Streams::AioStreamsProvider, CometService, Streams::TorrentioProvider ])
    end

    it 'queries both debrid services when both keys are present, preferred one first' do
      ENV["STREAM_PROVIDER"] = "torrentio"

      providers = described_class.providers(rd_api_key: 'rd_key', torbox_api_key: 'tb_key', debrid_service: "torbox")

      expect(providers.map { |provider| provider.instance_variable_get(:@debrid_service) }).to eq(%w[torbox realdebrid])
      expect(providers.map { |provider| provider.instance_variable_get(:@api_key) }).to eq(%w[tb_key rd_key])
    end

    it 'queries the other service when it is the only one with a key' do
      ENV["STREAM_PROVIDER"] = "torrentio"

      providers = described_class.providers(rd_api_key: nil, torbox_api_key: 'tb_key', debrid_service: "realdebrid")

      expect(providers.length).to eq(1)
      expect(providers.first.instance_variable_get(:@debrid_service)).to eq("torbox")
    end

    it 'queries Comet once per debrid service' do
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "https://comet.example.com"

      providers = described_class.providers(rd_api_key: 'rd_key', torbox_api_key: 'tb_key')

      expect(providers.map(&:class)).to eq([ CometService, CometService, Streams::TorrentioProvider, Streams::TorrentioProvider ])
    end

    it 'passes the TorBox key and service to Torrentio' do
      ENV["STREAM_PROVIDER"] = "torrentio"

      provider = described_class.providers(rd_api_key: nil, torbox_api_key: "tb_key", debrid_service: "torbox").first

      expect(provider.instance_variable_get(:@api_key)).to eq("tb_key")
      expect(provider.instance_variable_get(:@debrid_service)).to eq("torbox")
    end
  end

  describe '.keyless_provider_available?' do
    it 'is true when AIOStreams is selected and configured' do
      ENV["STREAM_PROVIDER"] = "aiostreams"
      ENV["AIOSTREAMS_URL"] = "https://aiostreams.example.com/stremio/uuid/manifest.json"

      expect(described_class.keyless_provider_available?).to be true
    end

    it 'is false when AIOStreams is configured but not selected' do
      ENV["STREAM_PROVIDER"] = "torrentio"
      ENV["AIOSTREAMS_URL"] = "https://aiostreams.example.com/stremio/uuid"

      expect(described_class.keyless_provider_available?).to be false
    end

    it 'is false when AIOStreams is selected but not configured' do
      ENV["STREAM_PROVIDER"] = "aiostreams"
      ENV["AIOSTREAMS_URL"] = nil

      expect(described_class.keyless_provider_available?).to be false
    end
  end

  describe '.resolve_base_urls' do
    it 'includes torrentio URLs by default' do
      ENV["STREAM_PROVIDER"] = nil
      urls = described_class.resolve_base_urls
      expect(urls).to include(Streams::TorrentioProvider::BASE_URL)
      expect(urls).to include('https://torrentio.strem.fun')
    end

    it 'includes comet URL when configured' do
      ENV["STREAM_PROVIDER"] = "comet"
      ENV["COMET_URL"] = "https://comet.example.com"
      urls = described_class.resolve_base_urls
      expect(urls).to include('https://comet.example.com')
    end

    it 'includes the AIOStreams base when configured' do
      ENV["STREAM_PROVIDER"] = "aiostreams"
      ENV["AIOSTREAMS_URL"] = "https://aiostreams.example.com/stremio/uuid/manifest.json"
      urls = described_class.resolve_base_urls
      expect(urls).to include('https://aiostreams.example.com/stremio/uuid')
    end

    it 'returns unique URLs' do
      ENV["STREAM_PROVIDER"] = "torrentio"
      urls = described_class.resolve_base_urls
      expect(urls).to eq(urls.uniq)
    end
  end
end
