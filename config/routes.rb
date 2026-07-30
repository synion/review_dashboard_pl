Rails.application.routes.draw do
  root "projects#index"

  # Zagnieżdżamy tylko to, co bez projektu nie ma sensu. Review należy do jednego
  # projektu na stałe, więc :project_id w adresie pokazu byłby redundantny — a jego
  # brak zostawia wszystkie akcje pojedynczego review nietknięte.
  resources :projects, except: :destroy do
    # Kolejka „czeka na Twoje review" jest wspólna dla wszystkich projektów, więc
    # jej odświeżenie nie należy do żadnego pojedynczego.
    collection do
      post :refresh_inbox
      # Przełącznik głównego projektu — collection, bo odpowiedzią jest przebudowa
      # kolejek całej strony wejściowej, a nie widok jednego projektu.
      post :select
    end
    member do
      post :archive
      post :unarchive
    end
    resources :reviews, only: %i[index new create] do
      collection do
        post :recheck_github
      end
    end
  end

  resources :reviews, only: %i[show destroy] do
    member do
      post :start
      post :abort
      post :retry_run
      post :refresh_task_description
      post :remove_worktree
      post :reimport
      post :switch_config
      post :compact
      post :verify_fixes
    end
    resources :playwright_runs, only: :create
    resource :decision, only: :create
    resource :followup, only: :create
    resource :task_comment, only: :create
  end
end
