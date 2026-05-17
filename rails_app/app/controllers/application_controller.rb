class ApplicationController < ActionController::Base
  before_action :require_login

  helper_method :current_user, :current_organization, :employee_user?

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id].present?
  end

  def current_organization
    @current_organization ||= current_user&.organization
  end

  def employee_user?
    current_user&.user?
  end

  def after_login_path_for(user)
    user&.user? ? employee_workspace_path : root_path
  end

  def current_workspace_path
    employee_user? ? employee_workspace_path : root_path
  end

  def require_admin!
    head :forbidden unless current_user&.admin?
  end

  def require_login
    redirect_to new_session_path, alert: "Войдите в систему" unless current_user
  end
end
