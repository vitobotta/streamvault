# frozen_string_literal: true

class CollectionMembershipService
  def self.add_to_library(user:, attributes:)
    entry = user.library_entries.build(attributes)

    ActiveRecord::Base.transaction do
      entry.save!
      user.wishlist_entries.find_by(imdb_id: entry.imdb_id)&.destroy!
    end

    ServiceResult.success(entry)
  rescue ActiveRecord::RecordInvalid => e
    ServiceResult.failure(e.record.errors.full_messages.join(", "))
  end

  def self.move_to_library(user:, wishlist_entry:)
    library_entry = ActiveRecord::Base.transaction do
      entry = user.library_entries.find_or_initialize_by(imdb_id: wishlist_entry.imdb_id)
      entry.assign_attributes(
        content_type: wishlist_entry.content_type,
        title: wishlist_entry.title,
        poster_url: wishlist_entry.poster_url,
        year: wishlist_entry.year
      )
      entry.save!
      wishlist_entry.destroy!
      entry
    end

    ServiceResult.success(library_entry)
  rescue ActiveRecord::RecordInvalid => e
    ServiceResult.failure(e.record.errors.full_messages.join(", "))
  end
end
