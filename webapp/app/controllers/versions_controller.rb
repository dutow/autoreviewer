class VersionsController < ApplicationController
  def show
    version = ReviewsRoot.new.project(params[:project])
                        &.topic(params[:topic])
                        &.version(params[:version]) or return head :not_found
    file = version.default_file or return head :not_found
    redirect_to finding_file_path(version.project_name, version.topic_name, version.number, file.relpath)
  end
end
