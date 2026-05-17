require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

module MunicipalAgent
  class Application < Rails::Application
    config.load_defaults 8.0
    config.time_zone = "Europe/Moscow"
    config.active_job.queue_adapter = :sidekiq
    config.eager_load_paths << Rails.root.join("app/services")
  end
end

