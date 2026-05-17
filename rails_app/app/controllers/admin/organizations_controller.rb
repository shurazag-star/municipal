module Admin
  class OrganizationsController < ApplicationController
    before_action :require_admin!

    def index
      @organizations = Organization.order(:name)
    end
  end
end

