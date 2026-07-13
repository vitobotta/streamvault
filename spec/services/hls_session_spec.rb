require "rails_helper"

RSpec.describe HlsSession do
  let(:user) { create(:user) }
  let(:session_id) { SecureRandom.hex(16) }
  let(:segment_dir) { Rails.root.join("tmp", "hls", session_id) }

  def create_record(created_at: Time.current, updated_at: created_at, dir: segment_dir)
    FileUtils.mkdir_p(dir)
    record = HlsSessionRecord.create!(
      user: user,
      session_id: session_id,
      segment_dir: dir.to_s,
      pid: nil
    )
    record.update_columns(created_at: created_at, updated_at: updated_at)
    record
  end

  after do
    HlsSessionRecord.where(user: user).delete_all
    FileUtils.rm_rf(segment_dir)
  end

  describe ".find" do
    it "keeps a stream active beyond thirty minutes when segment requests continue" do
      record = create_record(created_at: 2.hours.ago, updated_at: 30.seconds.ago)

      session = described_class.find(session_id)

      expect(session).not_to be_nil
      expect(record.reload).to be_present
    end

    it "expires a session after thirty minutes without activity" do
      create_record(created_at: 2.hours.ago, updated_at: 31.minutes.ago)

      expect(described_class.find(session_id)).to be_nil
      expect(HlsSessionRecord.find_by(session_id: session_id)).to be_nil
      expect(segment_dir).not_to exist
    end

    it "enforces the absolute session lifetime even when recently active" do
      create_record(created_at: 13.hours.ago, updated_at: 30.seconds.ago)

      expect(described_class.find(session_id)).to be_nil
      expect(HlsSessionRecord.find_by(session_id: session_id)).to be_nil
    end
  end

  describe "#prune_consumed_segments" do
    it "deletes only segments safely behind Safari's requested segment" do
      create_record
      (0..10).each { |index| File.binwrite(segment_dir.join("#{index}.ts"), "segment") }
      session = described_class.find(session_id)

      session.prune_consumed_segments(10)

      remaining = Dir.glob(segment_dir.join("*.ts")).map { |path| File.basename(path, ".ts").to_i }.sort
      expect(remaining).to eq((4..10).to_a)
    end
  end

  describe ".cleanup_orphan_directories" do
    it "removes stale untracked directories without touching active sessions" do
      stale_time = 1.hour.ago.to_time
      active_dir = segment_dir
      create_record(dir: active_dir)
      File.utime(stale_time, stale_time, active_dir)

      orphan_dir = Rails.root.join("tmp", "hls", SecureRandom.hex(16))
      FileUtils.mkdir_p(orphan_dir)
      File.utime(stale_time, stale_time, orphan_dir)

      described_class.cleanup_orphan_directories

      expect(active_dir).to exist
      expect(orphan_dir).not_to exist
    ensure
      FileUtils.rm_rf(orphan_dir) if orphan_dir
    end
  end
end

RSpec.describe HlsSessionKiller do
  describe "#kill" do
    it "reaps an already-exited child when its process group is gone" do
      killer = described_class.new(123)
      allow(Process).to receive(:kill).with("CONT", -123).and_raise(Errno::ESRCH)
      allow(Process).to receive(:kill).with("TERM", -123).and_raise(Errno::ESRCH)
      expect(Process).to receive(:wait).with(123).and_raise(Errno::ECHILD)

      killer.kill
    end

    it "reaps a normally terminated child without waiting for the grace deadline" do
      pid = Process.spawn(
        RbConfig.ruby,
        "-e",
        "sleep 60",
        out: File::NULL,
        err: File::NULL,
        pgroup: true
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      described_class.new(pid).kill

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.75
      expect { Process.wait(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    ensure
      begin
        Process.kill("KILL", -pid) if pid
      rescue Errno::ESRCH
      end
      begin
        Process.wait(pid) if pid
      rescue Errno::ESRCH, Errno::ECHILD
      end
    end
  end
end
