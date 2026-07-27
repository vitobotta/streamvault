require 'rails_helper'

RSpec.describe StreamProvider, type: :service do
  around do |ex|
    old_provider = ENV["STREAM_PROVIDER"]
    old_comet = ENV["COMET_URL"]
    ex.run
  ensure
    ENV["STREAM_PROVIDER"] = old_provider
    ENV["COMET_URL"] = old_comet
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

      providers = described_class.providers(rd_api_key: 'test_key')
      expect(providers.length).to eq(1)
      expect(providers.first).to be_a(Streams::TorrentioProvider)
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

    it 'returns unique URLs' do
      ENV["STREAM_PROVIDER"] = "torrentio"
      urls = described_class.resolve_base_urls
      expect(urls).to eq(urls.uniq)
    end
  end
end
