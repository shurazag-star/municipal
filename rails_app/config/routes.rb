Rails.application.routes.draw do
  get "/favicon.ico", to: proc { [204, {}, []] }
  get "/up", to: proc { [200, { "Content-Type" => "text/plain" }, ["ok"]] }

  root "agent_workspace#show"

  resource :session, only: %i[new create destroy]
  resource :agent_workspace, only: %i[show]
  get "/employee", to: "employee_workspace#show", as: :employee_workspace
  resources :employee_documents, only: %i[create destroy] do
    collection do
      delete :clear_all
      delete :clear_current_program
    end
  end
  resources :agent_messages, only: %i[create]
  post "/agent/clear_chat", to: "agent_conversations#clear", as: :clear_agent_chat
  resource :agent_settings, only: %i[show update]

  resources :programs, only: %i[index show create]
  resources :program_versions, only: %i[show]
  get "/uploads", to: "source_documents#index"
  resources :uploads, only: %i[create]
  resources :source_documents, path: "documents", only: %i[index show create destroy] do
    collection do
      post :set_source_mode
      delete :clear_change_sources
      delete :clear_change_projects
      delete :clear_program_versions
      delete :clear_workspace
    end
    member do
      post :make_active
    end
  end
  resources :knowledge_chunks, path: "knowledge_base", only: %i[index]
  resources :analysis_sessions, only: %i[create show] do
    member do
      post :run_analysis
      post :create_change_set
    end
  end

  post "/imports/docx", to: "imports#docx"
  post "/imports/procedure_pdf", to: "imports#procedure_pdf"
  post "/imports/finance_xlsx", to: "imports#finance_xlsx"
  post "/imports/agreement_pdf", to: "imports#agreement_pdf"
  post "/agent/explain", to: "agent_explanations#create", as: :agent_explain

  resources :reconciliations, only: %i[create show]
  resources :change_sets, only: %i[index create show destroy] do
    member do
      post :confirm_item
      post :approve
      post :approve_generated
      post :reject_generated
      post :apply
      post :export_docx
      post :export_report
      get :export_docx
      get :export_report
    end
  end

  post "/documents/:id/export", to: "documents#export", as: :document_export

  namespace :admin do
    root "dashboard#index"
    resources :users, only: %i[index]
    resources :organizations, only: %i[index]
    resource :openrouter_settings, only: %i[show update] do
      post :load_models
    end
    resources :source_aliases, only: %i[index create]
    resources :llm_runs, only: %i[index]
    resources :audit_logs, only: %i[index]
  end
end
