require "rails_helper"

RSpec.describe Catalog::OmdbClient do
  it "ignores malformed optional ratings data" do
    response = double("response", body: {
      "Response" => "True",
      "Rated" => "PG-13",
      "Metascore" => "74",
      "Ratings" => { "Source" => "Rotten Tomatoes", "Value" => "87%" }
    })
    connection = double("connection")
    allow(connection).to receive(:get).and_return(response)

    result = described_class.new(api_key: "test-key", connection: connection).ratings("tt1375666")

    expect(result).to eq(rated: "PG-13", rt_rating: nil, metascore: "74")
  end
end

RSpec.describe Catalog::CinemetaClient do
  it "keeps primary metadata when optional ratings fail" do
    response = double("response", success?: true, body: {
      "meta" => {
        "id" => "tt1375666",
        "name" => "Inception",
        "runtime" => "148 min"
      }
    })
    connection = double("connection")
    ratings = instance_double(Catalog::OmdbClient)
    logger = double("logger", warn: nil)
    allow(connection).to receive(:get).and_return(response)
    allow(ratings).to receive(:ratings).and_raise(TypeError, "unexpected ratings shape")

    result = described_class.new(
      connection: connection,
      ratings: ratings,
      cache: ActiveSupport::Cache::MemoryStore.new,
      logger: logger
    ).metadata("tt1375666", "movie")

    expect(result).to be_success
    expect(result.data).to include(title: "Inception", runtime_seconds: 8_880)
    expect(logger).to have_received(:warn).with(/optional ratings failed: TypeError/)
  end
end
