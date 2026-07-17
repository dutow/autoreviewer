class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  PER_PAGE = 25

  before_action :require_login
  before_action :reindex_fallback

  helper_method :current_email

  private

  def current_email = session[:email]

  def require_login
    reset_session if ENV["AUTH_MODE"] != "none" && session[:email] == "local@localhost"

    return if session[:email]

    if ENV["AUTH_MODE"] == "none"
      session[:email] = "local@localhost"
      return
    end

    render "sessions/login", status: :unauthorized
  end

  def reindex_fallback
    Indexer.run_if_stale unless Rails.env.test?
  end

  def filtered_reviews(scope)
    scope = scope.latest_per_topic unless params[:versions] == "all"
    @total_count = scope.count
    @page_count = [(@total_count + PER_PAGE - 1) / PER_PAGE, 1].max
    @page = params[:page].to_s.to_i.clamp(1, @page_count)
    scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
  end
end
