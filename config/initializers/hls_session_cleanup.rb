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
    def start
      return unless Rails.env.production?
      return if ENV["HLS_CLEANUP_IN_WEB"].to_s.strip.downcase == "false"
      # Puma is loaded only by the web server, so bin/jobs, the console and the
      # release task never start a second loop.
      return unless defined?(Puma)

      lock = File.open(Rails.root.join(LOCK_PATH), File::RDWR | File::CREAT, 0o644)
      @lock = lock
      Rails.logger.info("[HlsSessionCleanup] starting web-side HLS cleanup loop")

      Thread.new do
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

Rails.application.config.after_initialize { HlsCleanup.start }
