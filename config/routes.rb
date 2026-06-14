Rails.application.routes.draw do
  devise_for :users

  # Root
  root "home#index"

  # Search
  resources :search, only: [:index]

  # Content detail
  get "content/:type/:imdb_id", to: "content#show", as: :content

  # Library
  resources :library, only: [:index, :create, :update, :destroy]

  # Wishlist
  resources :wishlist, only: [:index, :create, :destroy] do
    member do
      post :move_to_library
    end
  end

  # Watch History
  resources :watch_history, only: [:index] do
    collection do
      delete :clear_all
    end
  end

  # Episodes
  get "episodes/:show_imdb_id", to: "episodes#index", as: :episodes

  # Streaming
  resources :streaming, only: [:create, :show] do
    member do
      patch :progress
    end
  end

  # Settings
  get "settings", to: "settings#show", as: :settings
  patch "settings", to: "settings#update"

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
