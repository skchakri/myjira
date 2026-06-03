Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "projects#index"

  # Short, stable per-client URLs — pyr-docker links to /c/<client-slug>.
  # Auto-provisions the matching Project on first GET so external callers
  # never hit a 404.
  get "/c",        to: "clients#index", as: :clients
  get "/c/:slug",  to: "clients#show",  as: :client

  resources :projects do
    member { patch :color }
    resources :environments, except: [:index]
    resources :tasks, except: [:index] do
      resources :follow_up_tasks, only: [:new, :create], controller: "follow_up_tasks", as: :follow_ups
    end
    resources :test_plans do
      resources :test_cases, except: [:index]
      resources :test_runs, only: [:new, :create, :show, :index]
    end
    resources :follow_up_tasks, only: [:index, :edit, :update, :destroy]
    resources :browser_tasks, only: [:index, :new, :create]
    resources :conversations, only: [:index]
  end

  # Captured Claude CLI conversations (one thread per CLI session).
  resources :conversations, only: [:index, :show] do
    collection { get :live }
    member do
      patch :rename
      post :summarize
      post :command   # web → queue a command for the live session
    end
  end

  resources :test_runs, only: [:show] do
    member do
      post :complete
      post :execute
      post :playwright_execute
    end
  end

  # Shared CLI ⇄ Claude-in-Chrome relay channel (usually under the "general" project).
  resources :browser_tasks, only: [:index, :show] do
    member do
      post :kickoff
      post :complete
      post :cancel
      post :humanize
    end
    resources :browser_messages, only: [:create]
  end

  # Public API (no authentication)
  namespace :api do
    namespace :v1 do
      get "ping", to: "ping#show"
      get "spec",  to: "spec#show"

      # Cross-client overview. Mirrors /c/:slug as JSON for pyr-docker.
      resources :clients, only: [:index, :show], param: :slug

      resources :projects, only: [:index, :show, :create, :update] do
        resources :environments, only: [:index, :show, :create, :update]
        resources :tasks,        only: [:index, :show, :create, :update] do
          resources :follow_up_tasks, only: [:index, :create], path: "follow_ups"
        end
        resources :test_plans, only: [:index, :show, :create, :update] do
          resources :test_cases, only: [:index, :create, :update] do
            collection { post :bulk }
          end
          resources :test_runs, only: [:index, :show, :create]
        end
        resources :follow_up_tasks, only: [:index, :create, :update], path: "follow_ups"
        resources :browser_tasks, only: [:index, :create]
        resources :conversations, only: [:index]
      end

      # Claude CLI conversation capture. The Stop hook posts new turns to sync.
      resources :conversations, only: [:index, :show] do
        collection do
          post :sync
          get :name   # statusline looks up a session's name by session_id
        end
      end

      # Web → live session command channel, keyed by CLI session_id. The
      # `myjira-listen` listener long-polls index and PATCHes back the result.
      get   "sessions/:session_id/commands",     to: "session_commands#index"
      patch "sessions/:session_id/commands/:id", to: "session_commands#update"

      resources :test_runs, only: [:show, :update] do
        member do
          patch :complete
        end
        resources :test_results, only: [:index, :update], path: "results"
      end

      # CLI ⇄ Claude-in-Chrome relay. Both sides watch the same thread.
      resources :browser_tasks, only: [:index, :show, :update] do
        member do
          post :kickoff
          patch :complete
          post :cancel
        end
        resources :messages, only: [:index, :create], controller: "browser_messages"
      end
      get "inbox", to: "browser_tasks#inbox"
    end
  end
end
