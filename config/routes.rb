Rails.application.routes.draw do
  devise_for :users, controllers: { registrations: "users/registrations" }

  # Root
  root "home#index"

  # Search
  resources :search, only: [:index]

  # Content detail
  get "content/:type/:imdb_id", to: "content#show", as: :content
  get "content/:type/:imdb_id/status", to: "content#status", as: :content_status
  get "content/:type/:imdb_id/episode_streams", to: "content#episode_streams", as: :episode_streams

  # Library
  resources :library, only: [:index, :create, :update, :destroy]

  # Wishlist
  resources :wishlist, only: [:index, :create, :destroy] do
    member do
      post :move_to_library
    end
  end

  # Watch History
  resources :watch_history, only: [:index, :destroy] do
    collection do
      delete :clear_all
    end
  end

  # Episodes
  get "episodes/:show_imdb_id", to: "episodes#index", as: :episodes

  # Streaming
  resources :streaming, only: [:create, :show] do
    collection do
      get :resume
    end
    member do
      patch :progress
    end
  end

  # FFmpeg transcode proxy (MKV → fMP4 with AAC audio)
  get "transcode/duration", to: "transcode_duration#show", as: :transcode_duration
  get "transcode/tracks", to: "transcode_tracks#show", as: :transcode_tracks
  get "transcode/subtitles", to: "transcode_subtitles#show", as: :transcode_subtitles
  get "transcode", to: "transcode#stream", as: :transcode_stream

  # HLS streaming (iOS fallback — iPhone Safari lacks MSE support)
  post "hls/start", to: "hls#start", as: :hls_start
  get "hls/:id/playlist.m3u8", to: "hls#playlist", as: :hls_playlist
  get "hls/:id/:segment", to: "hls#segment", as: :hls_segment, constraints: { segment: /\d+\.ts/ }
  post "hls/:id/stop", to: "hls#stop", as: :hls_stop

  # Settings
  get "settings", to: "settings#show", as: :settings
  patch "settings", to: "settings#update"

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
