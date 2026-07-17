class HomeController < ApplicationController
  def index
    @reviews = ReviewVersion.newest_first
    @reviews = @reviews.where(project: params[:project]) if params[:project].present?
    @reviews = filtered_reviews(@reviews)
    @projects = ReviewVersion.distinct.order(:project).pluck(:project)
  end
end
