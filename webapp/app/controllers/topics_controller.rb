class TopicsController < ApplicationController
  def show
    project = ReviewsRoot.new.project(params[:project]) or return head :not_found
    topic = project.topic(params[:topic]) or return head :not_found
    version = topic.current_version or return head :not_found
    file = version.default_file or return head :not_found
    redirect_to finding_file_path(project.name, topic.name, version.number, file.relpath)
  end
end
