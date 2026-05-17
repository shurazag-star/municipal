require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "railway_bucket").to_sym
  config.active_job.queue_adapter = :sidekiq
  config.force_ssl = ENV.fetch("FORCE_SSL", "true") == "true"
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } } if config.force_ssl
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
end
