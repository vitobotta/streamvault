require "rails_helper"
require "open3"
require "shellwords"
require "tmpdir"

RSpec.describe "production process configuration" do
  it "runs Solid Queue in the dedicated Procfile worker" do
    procfile = Rails.root.join("Procfile").read
    web_process = procfile.lines.find { |line| line.start_with?("web:") }
    worker_process = procfile.lines.find { |line| line.start_with?("worker:") }

    expect(web_process).to include("SOLID_QUEUE_IN_PUMA=false")
    expect(worker_process).to include("bin/jobs")
  end

  it "executes the web command through the Docker entrypoint with Solid Queue disabled" do
    web_process = Rails.root.join("Procfile").read.lines.find { |line| line.start_with?("web:") }
    command = Shellwords.split(web_process.delete_prefix("web:"))

    Dir.mktmpdir("streamvault-process-spec") do |directory|
      bundle = File.join(directory, "bundle")
      File.write(bundle, "#!/bin/sh\nprintf '%s\\n' \"$SOLID_QUEUE_IN_PUMA\" \"$@\"\n")
      File.chmod(0o755, bundle)

      output, error, status = Open3.capture3(
        { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "SOLID_QUEUE_IN_PUMA" => nil },
        Rails.root.join("bin/docker-entrypoint").to_s, *command
      )

      expect(status.success?).to be(true), error
      expect(output.lines.map(&:chomp)).to eq(
        %w[false exec puma -t 5:5 -p 5000 -e production]
      )
    end
  end
end
