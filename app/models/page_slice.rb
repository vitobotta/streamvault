# frozen_string_literal: true

PageSlice = Data.define(:items, :page, :per_page, :total, :total_pages) do
  def self.from_relation(relation, page:, per_page:, max_per_page: 100)
    build(page: page, per_page: per_page, max_per_page: max_per_page, total: relation.count) do |offset, limit|
      relation.offset(offset).limit(limit)
    end
  end

  def self.from_array(items, page:, per_page:, max_per_page: 100)
    build(page: page, per_page: per_page, max_per_page: max_per_page, total: items.length) do |offset, limit|
      items.slice(offset, limit) || []
    end
  end

  def visible_pages(radius: 2)
    pages = [ 1, total_pages ]
    pages.concat(([ page - radius, 2 ].max..[ page + radius, total_pages - 1 ].min).to_a) if total_pages > 2
    pages.select { |number| number.between?(1, total_pages) }.uniq.sort
  end

  def any_pages?
    total_pages.positive?
  end
  def first_item_number
    total.zero? ? 0 : ((page - 1) * per_page) + 1
  end

  def last_item_number
    [ page * per_page, total ].min
  end


  private_class_method def self.build(page:, per_page:, max_per_page:, total:)
    normalized_per_page = per_page.to_i.clamp(1, max_per_page)
    total_pages = (total.to_f / normalized_per_page).ceil
    normalized_page = page.to_i.clamp(1, [ total_pages, 1 ].max)
    items = yield((normalized_page - 1) * normalized_per_page, normalized_per_page)

    new(
      items: items,
      page: normalized_page,
      per_page: normalized_per_page,
      total: total,
      total_pages: total_pages
    )
  end
end
