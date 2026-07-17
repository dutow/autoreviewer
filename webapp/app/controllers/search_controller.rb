class SearchController < ApplicationController
  def index
    @q = params[:q].to_s.strip
    @hits = @q.present? ? Document.search(@q) : []
  end
end
