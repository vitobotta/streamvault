# frozen_string_literal: true

# HLS sessions are created, transcoded and served by the web container: their
# rows carry PIDs and tmp/hls paths that exist nowhere else.  Running the
# cleanup from the worker would delete the rows while leaving every segment
# on the web disk, and could signal an unrelated process that reused the PID.
#
# With SOLID_QUEUE_IN_PUMA the scheduler already lives in Puma, so the thread
# below only starts when a separate worker owns job execution.
if Rails.env.production? &&
   ActiveModel::Type::Boolean.new.cast(ENV["SOLID_QUEUE_IN_PUMA"].presence || "false") != true &&
   ENV["HLS_CLEANUP_IN_WEB"] != "false"
  Rails.application.config.after_initialize do
    next unless defined?(Rails::Server)

    Rails.logger.info("[HlsSessionCleanup] starting web-side HLS cleanup loop")
    Thread.new do
      loop do
        begin
          Rails.application.executor.wrap { HlsSessionManager.cleanup_expired }
        rescue StandardError => e
          Rails.logger.warn("[HlsSessionCleanup] #{e.class}: #{e.message}")
        end
        sleep 300
      end
    end
  end
end
