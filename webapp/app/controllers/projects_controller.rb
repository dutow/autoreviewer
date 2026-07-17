class ProjectsController < ApplicationController
  def show
    @project = ReviewsRoot.new.project(params[:project]) or return head :not_found
    @reviews = filtered_reviews(ReviewVersion.newest_first.where(project: @project.name))
  end
end
