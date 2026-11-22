class CostsController < ApplicationController
  def index
    scope = ReviewVersion.all
    scope = scope.where(project: params[:project]) if params[:project].present?
    scope = scope.where(route: params[:route]) if params[:route].present?
    @stats = CostStats.new(scope)
    @projects = ReviewVersion.distinct.order(:project).pluck(:project)
    @routes = ReviewVersion.where.not(route: nil).distinct.order(:route).pluck(:route)
  end
end
