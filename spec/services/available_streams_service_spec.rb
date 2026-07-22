require "rails_helper"

RSpec.describe AvailableStreamsService do
  let(:user) { create(:user, realdebrid_api_key: "test_key") }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:provider) { double("provider") }
  subject(:service) { described_class.new(user, providers: [ provider ], cache: cache) }

  def stream_result(filename = "movie.mp4")
    ServiceResult.success([ { filename: filename, resolve_url: "https://provider.test/resolve/#{filename}" } ])
  end

  it "caches successful listings by content and language priority" do
    allow(provider).to receive(:streams).and_return(stream_result)

    first = service.call(imdb_id: "tt1375666", type: "movie", title: "Inception")
    second = service.call(imdb_id: "tt1375666", type: "movie", title: "Inception")

    expect(first).to be_success
    expect(second.data).to eq(first.data)
    expect(provider).to have_received(:streams).once
  end

  it "does not cache failed listings" do
    allow(provider).to receive(:streams).and_return(ServiceResult.failure("provider unavailable"))

    2.times { service.call(imdb_id: "tt1375666", type: "movie") }

    expect(provider).to have_received(:streams).twice
  end

  it "isolates provider exceptions and keeps successful provider results" do
    failing_provider = double("failing provider")
    successful_provider = double("successful provider")
    allow(failing_provider).to receive(:streams).and_raise(Net::ReadTimeout)
    allow(successful_provider).to receive(:streams).and_return(stream_result("working.mp4"))
    service = described_class.new(user, providers: [ failing_provider, successful_provider ], cache: cache)

    result = service.call(imdb_id: "tt1375666", type: "movie")

    expect(result).to be_success
    expect(result.data.pluck(:filename)).to eq([ "working.mp4" ])
  end

  it "uses a different cache entry after the language priority changes" do
    allow(provider).to receive(:streams).and_return(stream_result("english.mp4"), stream_result("french.mp4"))

    english = service.call(imdb_id: "tt1375666", type: "movie")
    user.update!(preferred_languages: [ "FRENCH" ], default_language: "FRENCH")
    french = service.call(imdb_id: "tt1375666", type: "movie")

    expect(english.data.pluck(:filename)).to eq([ "english.mp4" ])
    expect(french.data.pluck(:filename)).to eq([ "french.mp4" ])
    expect(provider).to have_received(:streams).twice
  end
end
