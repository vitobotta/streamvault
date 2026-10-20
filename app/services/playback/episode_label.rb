# frozen_string_literal: true

module Playback
  # Canonical, single-source formatting for episode labels.
  #
  # Every path that stores or renders an episode title — start, resume,
  # auto-advance, watch history, the player chrome — funnels through here so a
  # label can never diverge between entry points.  Catalogue providers are
  # inconsistent: some episodes genuinely have no name, and some report a
  # synthetic "Episode 7" placeholder.  Both must degrade to a clean
  # "Show · S01E07" instead of showing a wrong or duplicated title.
  module EpisodeLabel
    SEPARATOR = " · "

    # "Episode 7", "Ep 7", "EPISODE 07", "Episode TBA", or a bare "7".
    PLACEHOLDER = /\A(?:episode|ep)\.?\s*\d*\s*(?:\(?tba\)?)?\z/i

    module_function

    def build(show_title: nil, season: nil, episode: nil, episode_title: nil)
      position = position(season, episode)
      name = clean(episode_title)
      name = nil if placeholder?(name, episode)

      [ clean(show_title), position, name ].compact.join(SEPARATOR).presence
    end

    # Splits a canonical label back into its parts.  Episode names may contain
    # the separator themselves, so everything after the position is rejoined.
    def split(label)
      parts = label.to_s.split(SEPARATOR)
      case parts.length
      when 0, 1
        { show_title: parts.first.presence, position: nil, episode_title: nil }
      when 2
        { show_title: parts[0].presence, position: parts[1].presence, episode_title: nil }
      else
        {
          show_title: parts[0].presence,
          position: parts[1].presence,
          episode_title: parts[2..].join(SEPARATOR).presence
        }
      end
    end

    # The two lines the player chrome renders, so the episode name is the
    # headline and the show/position is the context line.
    def present(label)
      parts = split(label)
      if parts[:episode_title].present?
        {
          title: parts[:episode_title],
          subtitle: [ parts[:show_title], parts[:position] ].compact.join(SEPARATOR).presence,
          position: parts[:position]
        }
      elsif parts[:position].present?
        { title: parts[:show_title] || parts[:position], subtitle: parts[:position], position: parts[:position] }
      else
        { title: parts[:show_title] || label.to_s.presence, subtitle: nil, position: nil }
      end
    end

    # "S01E07" — the short badge used by the player and history rows.
    def position(season, episode)
      season_number = integer(season)
      episode_number = integer(episode)
      return nil if season_number.nil? || episode_number.nil?

      format("S%02dE%02d", season_number, episode_number)
    end

    def placeholder?(title, episode)
      return false if title.nil?

      stripped = title.strip
      return true if stripped.match?(PLACEHOLDER)

      episode_number = integer(episode)
      !episode_number.nil? && stripped == episode_number.to_s
    end

    def clean(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def integer(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value.to_s, exception: false)
    end
  end
end
