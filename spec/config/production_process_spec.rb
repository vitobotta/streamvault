require "rails_helper"

RSpec.describe "production process configuration" do
  it "runs Solid Queue inside the Procfile Puma process" do
    procfile = Rails.root.join("Procfile").read
    web_process = procfile.lines.find { |line| line.start_with?("web:") }

    expect(web_process).to include("SOLID_QUEUE_IN_PUMA=true")
    expect(procfile).not_to match(/^worker:/)
  end
end
