ENV["RAILS_ENV"] = "test"

require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  parallelize(workers: 1)

  def create_user!(email: "admin@example.com", password: "password123", role: "admin")
    organization = Organization.find_or_create_by!(name: "Муниципальный округ Шатура") do |org|
      org.municipality_name = "Шатура"
      org.region_name = "Московская область"
    end
    user = User.find_or_initialize_by(email: email)
    user.password = password
    user.role = role
    user.organization = organization
    user.save!
    user
  end

  def create_isolated_user!(email:, password: "password123", role: "admin")
    organization = Organization.create!(
      name: "Муниципальный округ Шатура",
      municipality_name: "Шатура",
      region_name: "Московская область"
    )
    User.create!(
      email: email,
      password: password,
      role: role,
      organization: organization
    )
  end
end
