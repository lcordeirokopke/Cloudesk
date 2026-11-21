Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Entrada dos canais: WhatsApp (formato da Cloud API), chat (JSON assinado) e webhook do Mailpit.
  scope "channels", module: "channels" do
    get "whatsapp/webhook", to: "whatsapp_webhooks#verify", as: :whatsapp_webhook
    post "whatsapp/webhook", to: "whatsapp_webhooks#receive"
    post "chat/messages", to: "chat_messages#create", as: :chat_api_messages
    post "email/mailpit", to: "mailpit_webhooks#create", as: :mailpit_webhook
  end

  # Widget de chat in-app, por marca.
  scope "chat/:brand", module: "channels", controller: "chat_widget" do
    get "/", action: :index, as: :chat
    post "session", action: :create_session, as: :chat_session
    get "conversation", action: :conversation, as: :chat_conversation
    post "messages", action: :create_message, as: :chat_messages
  end

  # API do agente: ações chamadas pelo Broker e contexto lido pelo agente, ambas assinadas.
  scope "api/v1/agent", module: "api/v1/agent" do
    post "actions", to: "actions#create", as: :agent_actions
    get "brands/:brand/conversations/:conversation_id/context", to: "contexts#show", as: :agent_conversation_context
  end

  # Painel do analista (Hotwire), com HTTP basic auth e login simulado do analista na sessão.
  scope "panel", module: "panel", as: "panel" do
    root to: "sessions#index"
    post "session", to: "sessions#create", as: :session
    delete "session", to: "sessions#destroy"
    get "queue", to: "queues#show", as: :queue
    post "assignments", to: "assignments#create", as: :assignments
    get "conversations/:id", to: "conversations#show", as: :conversation
    post "conversations/:conversation_id/replies", to: "replies#create", as: :conversation_replies
    post "conversations/:conversation_id/resolution", to: "resolutions#create", as: :conversation_resolution
    post "handoffs/:handoff_id/rating", to: "handoff_ratings#create", as: :handoff_rating
  end

  # Painel dos jobs do Solid Queue (Mission Control - Jobs), com HTTP basic auth.
  mount MissionControl::Jobs::Engine, at: "/jobs"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
