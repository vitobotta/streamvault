module ApplicationHelper
  # A child account only sees titles whose certification resolves. With no
  # rating source configured, every title is "unrated" and hidden, so say why
  # rather than showing an empty catalogue.
  def parental_rating_sources_missing?
    return false unless current_user&.child_account?
    return @parental_rating_sources_missing unless @parental_rating_sources_missing.nil?

    @parental_rating_sources_missing = !ParentalControls::RatingResolver.sources_configured?
  end

  def player_time(seconds)
    total_seconds = seconds.to_f
    return "0:00" unless total_seconds.finite? && total_seconds.positive?

    total_seconds = total_seconds.floor
    hours = total_seconds / 3600
    minutes = (total_seconds % 3600) / 60
    seconds = total_seconds % 60

    if hours.positive?
      "#{hours}:#{minutes.to_s.rjust(2, '0')}:#{seconds.to_s.rjust(2, '0')}"
    else
      "#{minutes}:#{seconds.to_s.rjust(2, '0')}"
    end
  end

  # Metahub serves the same poster at three sizes; cards read much sharper at medium.
  def poster_url_for(url)
    return url if url.blank?

    url.to_s.sub("/poster/small/", "/poster/medium/")
  end

  def account_name(user)
    user.display_name.presence || user.email.to_s.split("@").first
  end

  def account_initials(user)
    name = account_name(user).to_s
    initials = name.split(/[\s._-]+/).reject(&:blank?).first(2).map { |part| part[0] }.join
    (initials.presence || name[0] || "?").upcase
  end

  # Favicons are cached by browsers for days and are not revalidated on reload.
  # Version the URL from the file's mtime so a changed icon gets a new address.
  def versioned_icon_path(path)
    file = Rails.root.join("public", path.delete_prefix("/"))
    return path unless file.file?

    "#{path}?v=#{file.mtime.to_i}"
  end
end
