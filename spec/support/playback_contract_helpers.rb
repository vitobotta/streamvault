# frozen_string_literal: true

module PlaybackContractHelpers
  DEFAULT_MEDIA_URL = "https://download.real-debrid.com/d/file123/video.mp4"

  def signed_source_for(user, url: DEFAULT_MEDIA_URL, filename: nil)
    ResolvedSource.issue(user: user, url: url, filename: filename)
  end

  def signed_playback_for(user, url: DEFAULT_MEDIA_URL, filename: "video.mp4", imdb_id: "tt1375666", type: "movie", season: nil, episode: nil, **attributes)
    PlaybackDescriptor.issue(
      user: user,
      source_token: signed_source_for(user, url: url, filename: filename),
      filename: filename,
      content_ref: ContentRef.new(imdb_id: imdb_id, type: type, season: season, episode: episode),
      **attributes
    )
  end

  def redirected_playback_descriptor(response, user:)
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    PlaybackDescriptor.resolve(token: query.fetch("playback"), user: user)
  end
end

RSpec.configure do |config|
  config.include PlaybackContractHelpers, type: :request
end
