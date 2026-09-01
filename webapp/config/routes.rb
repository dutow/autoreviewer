Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  get "auth/google_oauth2/callback" => "sessions#create"
  get "auth/failure" => "sessions#failure"
  delete "logout" => "sessions#destroy", as: :logout

  get "search" => "search#index", as: :search

  # default segment regexp stops at dots; project and topic names may contain them
  constraints project: ReviewsRoot::NAME_SEGMENT, topic: ReviewsRoot::NAME_SEGMENT do
    get "p/:project" => "projects#show", as: :project
    get "p/:project/t/:topic" => "topics#show", as: :topic
    get "p/:project/t/:topic/v/:version" => "versions#show", as: :version, constraints: { version: /\d+/ }
    get "p/:project/t/:topic/v/:version/f/*relpath" => "files#show", as: :finding_file,
        constraints: { version: /\d+/ }, format: false
  end

  # Defines the root path route ("/")
  root "home#index"
end
