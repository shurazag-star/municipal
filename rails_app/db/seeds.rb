fetch_seed_secret = lambda do |key, development_default|
  value = ENV[key].presence
  return value if value.present?
  return development_default unless Rails.env.production?

  raise "#{key} is required for production seeds"
end

organization = Organization.find_or_create_by!(name: "Муниципальный округ Шатура") do |org|
  org.municipality_name = "Шатура"
  org.region_name = "Московская область"
  org.settings = {
    money_tolerance_rub: ENV.fetch("MONEY_TOLERANCE_RUB", "10"),
    openrouter_model_primary: ENV.fetch("OPENROUTER_MODEL_PRIMARY", "deepseek/deepseek-v4-pro"),
    openrouter_model_fast: ENV.fetch("OPENROUTER_MODEL_FAST", "deepseek/deepseek-v4-flash")
  }
end
unless organization.settings["default_source_mode"].present?
  organization.update!(settings: organization.settings.merge("default_source_mode" => "auto"))
end

reset_seed_passwords = Rails.env.production? || ActiveModel::Type::Boolean.new.cast(ENV["RESET_DEMO_PASSWORDS"])

admin = User.find_or_initialize_by(email: ENV.fetch("ADMIN_EMAIL", "admin@example.com"))
admin.password = fetch_seed_secret.call("ADMIN_PASSWORD", "password123") if admin.new_record? || reset_seed_passwords
admin.role = "admin"
admin.organization = organization
admin.save!

employee = User.find_or_initialize_by(email: ENV.fetch("EMPLOYEE_EMAIL", "11@11"))
employee.password = fetch_seed_secret.call("EMPLOYEE_PASSWORD", "1111") if employee.new_record? || reset_seed_passwords
employee.role = "user"
employee.organization = organization
employee.save!

if ActiveModel::Type::Boolean.new.cast(ENV["LOAD_DEMO_DATA"])
  program = MunicipalProgram.find_or_create_by!(organization: organization, name: "Развитие жилищно-коммунального хозяйства") do |municipal_program|
    municipal_program.period_start_year = 2026
    municipal_program.period_end_year = 2030
  end

  version = program.current_version || program.program_versions.first ||
    program.program_versions.create!(created_by: admin, version_number: 1, status: "imported")
  program.update!(current_version: version) unless program.current_version_id == version.id
end
