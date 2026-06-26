Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "projects#index"

  # Short, stable per-client URLs — pyr-docker links to /c/<client-slug>.
  # Auto-provisions the matching Project on first GET so external callers
  # never hit a 404.
  get "/c",        to: "clients#index", as: :clients
  get "/c/:slug",  to: "clients#show",  as: :client

  resources :projects do
    member do
      patch :color
      patch :archive
      patch :unarchive
    end
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
    # Web → launch a new interactive Claude CLI session in this project's repo.
    resources :session_launches, only: [:create]
    # Web → trigger a discovered agent/skill/command (becomes a SessionLaunch),
    # or remove one from this folder's strip.
    resources :agents, only: [:destroy], controller: "agent_triggers" do
      member { post :trigger }
    end
    # Web → have Claude author an agent (create) or analyse the repo and propose
    # several (suggest); each queues a SessionLaunch that writes .claude/agents/.
    resources :agent_builds, only: [:create] do
      collection { post :suggest }
    end
    # Web → schedule a recurring trigger in this project's repo.
    resources :agent_schedules, only: [:create]
    # Web → add an MCP server (one-click from the catalog, or a custom spec);
    # files an McpInstall the host daemon runs with `claude mcp add`.
    resources :mcp_installs, only: [:create]
    # Turbo-frame source for this folder's configured-server pills — auto-reloads
    # so added/removed servers appear without a full page reload.
    resources :mcp_servers, only: [:index]
  end

  # Project board — the priority queue of typed work items for a folder, plus its
  # autopilot controls. Defined with an explicit :project_id (rather than nested
  # in `resources :projects`) so the helpers are board_path(project) /
  # board_item_path(project, item), and item actions sit cleanly under board/items.
  scope "projects/:project_id" do
    get   "board",                     to: "boards#show",        as: :board
    post  "board/reorder",             to: "boards#reorder",     as: :board_reorder
    post  "board/tick",                to: "boards#tick_now",    as: :board_tick
    patch "board/autopilot",           to: "boards#autopilot",   as: :board_autopilot
    post  "board/items",               to: "boards#create_item", as: :board_items
    patch "board/items/:id",           to: "boards#update_item", as: :board_item
    post  "board/items/:id/pick_up",   to: "boards#pick_up",     as: :board_item_pick_up
    post  "board/items/:id/run_tests", to: "boards#run_tests",   as: :board_item_run_tests
    post  "board/items/:id/merge",     to: "boards#request_merge", as: :board_item_merge
    post  "board/items/:id/reject",    to: "boards#reject_pr",   as: :board_item_reject
    post  "board/items/:id/comments",  to: "boards#add_comment", as: :board_item_comments
    get   "board/items/:id/plan",      to: "boards#plan",        as: :board_item_plan
    get   "board/items/:id/pr",        to: "boards#pr",          as: :board_item_pr
    post "jira_imports", to: "jira_imports#create", as: :project_jira_imports
  end

  # Global Jira connection (singleton credentials for ticket import).
  get   "jira/connection/edit", to: "jira_connections#edit",   as: :edit_jira_connection
  patch "jira/connection",      to: "jira_connections#update", as: :jira_connection

  # Global autopilot kill switch — stop/resume every project's pipeline at once.
  post "autopilot/stop_all",   to: "boards#stop_all",   as: :autopilot_stop_all
  post "autopilot/resume_all", to: "boards#resume_all", as: :autopilot_resume_all

  # Schedule lifecycle (pause/resume, run once now, remove).
  resources :agent_schedules, only: [:destroy] do
    member do
      post :toggle
      post :run_now
    end
  end

  # Remove a configured MCP server (files a `claude mcp remove` for the daemon).
  resources :mcp_servers, only: [:destroy]

  # Auto-reloading "Configuring MCP" strip (in-flight installs across projects).
  resources :mcp_installs, only: [] do
    collection { get :active }
  end

  # Launch lifecycle (cancel a queued one; auto-reloading "active launches" strip).
  resources :session_launches, only: [] do
    member { post :cancel }
    collection { get :active }
  end

  # Captured Claude CLI conversations (one thread per CLI session).
  resources :conversations, only: [:index, :show] do
    collection { get :live }
    member do
      patch :rename
      post :summarize
      post :command   # web → queue a command for the live session
      get :document   # open a file this session created (?path=…)
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
          member { post :finish } # agent signals "coding done" → fire the test leg
          resources :follow_up_tasks, only: [:index, :create], path: "follow_ups"
          resources :comments, only: [:index, :create]
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

      # Host-side launcher daemon: poll for queued launches, report status back.
      resources :session_launches, only: [:update] do
        collection { get :pending }
      end

      # Host-side daemon pushes the .claude agent/skill/command catalogue here.
      resources :agents, only: [] do
        collection { post :sync }
      end

      # Host-side daemon ticks this each loop; myjira fires any due schedules.
      resources :agent_schedules, only: [] do
        collection { post :tick }
      end

      # Host-side daemon ticks this each loop; myjira advances each autopilot
      # project's board pipeline by one step (one item at a time). GET status is
      # a read-only snapshot for the board header / debugging.
      post "autopilot/tick",   to: "autopilot#tick"
      get  "autopilot/status", to: "autopilot#status"

      # Host-side daemon: reconcile in_review PRs. GET = what to merge/poll;
      # POST = apply the gh outcomes (merge done, externally merged/closed).
      get  "board/pr_sync", to: "board#pr_sync"
      post "board/pr_sync", to: "board#pr_sync_apply"

      # Host-side daemon: poll for queued MCP add/remove requests, report back.
      resources :mcp_installs, only: [:update] do
        collection { get :pending }
      end

      # Host-side daemon pushes the current `claude mcp list` catalogue here.
      resources :mcp_servers, only: [] do
        collection { post :sync }
      end

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
