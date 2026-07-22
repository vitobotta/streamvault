require "rails_helper"

RSpec.describe HomeCatalogService do
  let(:torrentio) { instance_double(TorrentioService) }
  let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }
  subject(:service) { described_class.new(torrentio, logger: logger) }

  it "returns each catalog under its presentation key" do
    allow(torrentio).to receive(:popular).with("movie", limit: 20).and_return(ServiceResult.success([ :popular_movie ]))
    allow(torrentio).to receive(:popular).with("show", limit: 20).and_return(ServiceResult.success([ :popular_show ]))
    allow(torrentio).to receive(:trending).with("movie", limit: 20).and_return(ServiceResult.success([ :trending_movie ]))
    allow(torrentio).to receive(:trending).with("show", limit: 20).and_return(ServiceResult.success([ :trending_show ]))

    result = service.call

    expect(result.transform_values(&:data)).to eq(
      popular: [ :popular_movie ],
      popular_shows: [ :popular_show ],
      trending: [ :trending_movie ],
      trending_shows: [ :trending_show ]
    )
  end

  it "isolates a failed catalog from successful catalogs" do
    allow(torrentio).to receive(:popular).with("movie", limit: 20).and_raise(Net::ReadTimeout)
    allow(torrentio).to receive(:popular).with("show", limit: 20).and_return(ServiceResult.success([]))
    allow(torrentio).to receive(:trending).and_return(ServiceResult.success([]))

    result = service.call

    expect(result[:popular]).to be_failure
    expect(result[:popular_shows]).to be_success
    expect(result[:trending]).to be_success
    expect(result[:trending_shows]).to be_success
  end
end
