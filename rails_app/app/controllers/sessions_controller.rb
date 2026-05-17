class SessionsController < ApplicationController
  skip_before_action :require_login

  def new
    redirect_to after_login_path_for(current_user) if current_user
  end

  def create
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      session[:user_id] = user.id
      redirect_to after_login_path_for(user)
    else
      redirect_to new_session_path, alert: "Неверный email или пароль"
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to new_session_path
  end
end
