class PublicFilesController < ApplicationController
  before_action { request.format = :html }

  def show
    files = PublicFiles.new
    @segs = params[:relpath].to_s.split("/").reject(&:empty?)
    abs = files.resolve(@segs.join("/")) or return head :not_found

    unless File.directory?(abs)
      return head :not_found if trailing_slash?
      return send_public_file(abs)
    end

    unless trailing_slash?
      query = request.query_string.present? ? "?#{request.query_string}" : ""
      return redirect_to "#{request.path}/#{query}"
    end

    index = files.resolve((@segs + ["index.html"]).join("/"))
    return send_public_file(index) if params[:list].blank? && index && File.file?(index)

    @entries = files.entries(abs)
  end

  private

  # router strips the trailing slash from path_info before we run; the
  # original request line still has it
  def trailing_slash?
    request.original_fullpath.split("?", 2).first.end_with?("/")
  end

  def send_public_file(abs)
    stat = File.stat(abs)
    return unless stale?(etag: "#{stat.size}-#{stat.mtime.to_i}", last_modified: stat.mtime)

    send_file abs, filename: File.basename(abs), disposition: "inline",
              type: Rack::Mime.mime_type(File.extname(abs))
  end
end
