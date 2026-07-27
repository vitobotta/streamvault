# frozen_string_literal: true

class HomeCatalogService
  CATALOGS = {
    popular: [ :popular, "movie" ],
    popular_shows: [ :popular, "show" ],
    trending: [ :trending, "movie" ],
    trending_shows: [ :trending, "show" ]
  }.freeze

  def initialize(catalog, limit: 20, logger: Rails.logger)
    @catalog = catalog
    @limit = limit
    @logger = logger
  end

  def call
    CATALOGS.to_h do |name, (method_name, type)|
      [ name, Thread.new { fetch(name, method_name, type) } ]
    end.transform_values(&:value)
  end

  private

  def fetch(name, method_name, type)
    @catalog.public_send(method_name, type, limit: @limit)
  rescue StandardError => e
    @logger.warn("[HomeCatalogService] #{name} failed: #{e.class}: #{e.message}")
    ServiceResult.failure("Unable to load #{name.to_s.tr('_', ' ')}")
  end
end
