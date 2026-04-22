Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "projects#index"

  resources :projects do
    resources :environments, except: [:index]
    resources :tasks, except: [:index] do
      resources :follow_up_tasks, only: [:new, :create], controller: "follow_up_tasks", as: :follow_ups
    end
    resources :test_plans do
      resources :test_cases, except: [:index]
      resources :test_runs, only: [:new, :create, :show, :index]
    end
    resources :follow_up_tasks, only: [:index, :edit, :update, :destroy]
  end

  resources :test_runs, only: [:show] do
    member do
      post :complete
    end
  end

  # Public API (no authentication)
  namespace :api do
    namespace :v1 do
      get "ping", to: "ping#show"
      get "spec",  to: "spec#show"

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
      end

      resources :test_runs, only: [:show, :update] do
        member do
          patch :complete
        end
        resources :test_results, only: [:index, :update], path: "results"
      end
    end
  end
end
