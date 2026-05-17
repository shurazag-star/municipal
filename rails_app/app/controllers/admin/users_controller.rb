module Admin
  class UsersController < ApplicationController
    before_action :require_admin!

    def index
      @users = User.order(:email)
    end
  end
end

