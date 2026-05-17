Rails.application.config.filter_parameters += [
  :password,
  :password_digest,
  :token,
  :api_key,
  :OPENROUTER_API_KEY
]

