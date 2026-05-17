require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.public_file_server.headers = { "Cache-Control" => "public, max-age=#{1.hour.to_i}" }
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable
  config.active_storage.service = :local
  config.active_support.deprecation = :stderr
  config.active_job.queue_adapter = :test
  config.action_controller.allow_forgery_protection = false
end
