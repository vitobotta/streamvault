# frozen_string_literal: true

# Inline icon set shared by the navigation, cards and detail surfaces.
# Every icon is a 24x24 stroke glyph that inherits currentColor.
module IconHelper
  PATHS = {
    home: '<path d="M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/>',
    library: '<rect x="3.5" y="4.5" width="5" height="15" rx="1.2"/><rect x="10.5" y="4.5" width="5" height="15" rx="1.2"/><path d="m18.4 5.6 2.3 13.2"/>',
    wishlist: '<path d="M12 20s-7.5-4.6-7.5-9.6A4.4 4.4 0 0 1 12 7.4a4.4 4.4 0 0 1 7.5 3C19.5 15.4 12 20 12 20Z"/>',
    history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3.5 5.5V10H8"/><path d="M12 8.5V12l2.6 1.6"/>',
    playlist: '<path d="M4 6h10M4 12h10M4 18h7"/><path d="M17 9v8"/><path d="m14 15 3 3 3-3"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1.03 1.56V21a2 2 0 1 1-4 0v-.06a1.7 1.7 0 0 0-1.1-1.56 1.7 1.7 0 0 0-1.88.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.56-1.03H3a2 2 0 1 1 0-4h.06A1.7 1.7 0 0 0 4.6 8.87a1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34H9a1.7 1.7 0 0 0 1.03-1.56V3a2 2 0 1 1 4 0v.06a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87V9a1.7 1.7 0 0 0 1.56 1.03H21a2 2 0 1 1 0 4h-.06A1.7 1.7 0 0 0 19.4 15Z"/>',
    play: '<path d="M8 5.5v13l10-6.5z" fill="currentColor" stroke="none"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7"/>',
    x: '<path d="M6 6l12 12M18 6 6 18"/>',
    chevron_left: '<path d="m14.5 6-6 6 6 6"/>',
    chevron_right: '<path d="m9.5 6 6 6-6 6"/>',
    chevron_down: '<path d="m6 9.5 6 6 6-6"/>',
    arrow_left: '<path d="M19 12H5"/><path d="m11 6-6 6 6 6"/>',
    arrow_right: '<path d="M5 12h14"/><path d="m13 6 6 6-6 6"/>',
    clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 1.8"/>',
    star: '<path d="m12 4.5 2.3 4.8 5.2.7-3.8 3.7.9 5.2-4.6-2.5-4.6 2.5.9-5.2L4.5 10l5.2-.7z"/>',
    lock: '<rect x="5" y="10.5" width="14" height="9.5" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/>',
    user: '<circle cx="12" cy="8.5" r="3.5"/><path d="M4.5 20a7.5 7.5 0 0 1 15 0"/>',
    logout: '<path d="M15 5.5H7.5A1.5 1.5 0 0 0 6 7v10a1.5 1.5 0 0 0 1.5 1.5H15"/><path d="M18 12H10"/><path d="m15.5 8.5 3.5 3.5-3.5 3.5"/>',
    filter: '<path d="M5 7h14M8 12h8M10.5 17h3"/>',
    download: '<path d="M12 4.5v11"/><path d="m7.5 11.5 4.5 4.5 4.5-4.5"/><path d="M5 19.5h14"/>'
  }.freeze

  def icon(name, css: nil)
    path = PATHS.fetch(name.to_sym)
    content_tag(
      :svg,
      path.html_safe, # rubocop:disable Rails/OutputSafety -- static literals defined above
      class: css,
      viewBox: "0 0 24 24",
      fill: "none",
      stroke: "currentColor",
      "stroke-width": "1.6",
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
      "aria-hidden": "true",
      focusable: "false"
    )
  end
end
