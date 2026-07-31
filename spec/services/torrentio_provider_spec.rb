require "rails_helper"

RSpec.describe Streams::TorrentioProvider do
  it "allows slow fallback listings enough time to complete" do
    provider = described_class.new
    connection = provider.instance_variable_get(:@connection)

    expect(connection.options.timeout).to eq(30)
    expect(connection.options.open_timeout).to eq(5)
  end
end
