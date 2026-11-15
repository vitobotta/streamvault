# frozen_string_literal: true

# HLS sessions are created, transcoded and served by the web process: their
# rows carry PIDs and tmp/hls paths that exist nowhere else.  Solid Queue's
# scheduler lives in the worker when a separate worker container is deployed,
# and the single-container Procfile deployment has no worker at all, so the
# cleanup runs in the web process in both layouts.
module HlsCleanup
  INTERVAL = 5.minutes
  LOCK_PATH = "tmp/hls-cleanup.lock"

  class << self
    # Called from config/puma.rb's on_booted hook, so only the web server
    # process starts a loop: bin/jobs, the console and rake tasks never load
    # that config, and a phased restart cannot start a second one.
    def start
      return if @thread
      return unless Rails.env.production?
      return if ENV["HLS_CLEANUP_IN_WEB"].to_s.strip.downcase == "false"

      lock = File.open(Rails.root.join(LOCK_PATH), File::RDWR | File::CREAT, 0o644)
      @lock = lock
      Rails.logger.info("[HlsSessionCleanup] starting web-side HLS cleanup loop")

      @thread = Thread.new do
        loop do
          run_once(lock)
          sleep INTERVAL
        end
      end
    end

    private

    # The lock is taken per run and released afterwards, so a replacement
    # process takes over on the next cycle and clustered Puma workers never
    # run the cleanup at the same time.
    def run_once(lock)
      return unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      begin
        Rails.application.executor.wrap { HlsSessionManager.cleanup_expired }
      ensure
        lock.flock(File::LOCK_UN)
      end
    rescue StandardError => e
      Rails.logger.warn("[HlsSessionCleanup] #{e.class}: #{e.message}")
    end
  end
end
