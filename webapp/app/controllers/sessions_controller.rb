class SessionsController < ApplicationController
  skip_before_action :require_login

  def create
    email = request.env.dig("omniauth.auth", "info", "email")
    if AccessPolicy.allowed?(email)
      reset_session
      session[:email] = email
      redirect_to root_path
    else
      render :forbidden, status: :forbidden
    end
  end

  def failure
    flash.now[:alert] = "Sign-in failed: #{params[:message].to_s.humanize}"
    render :login, status: :unauthorized
  end

  def destroy
    reset_session
    redirect_to root_path
  end
end
