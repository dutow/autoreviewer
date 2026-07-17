class FilesController < ApplicationController
  # relpath carries the real file extension (.md, .patch, ...); don't let Rails
  # sniff that as the response format, we always render/download as-is.
  before_action { request.format = :html }

  def show
    version = ReviewsRoot.new.project(params[:project])
                        &.topic(params[:topic])
                        &.version(params[:version]) or return head :not_found
    @file = version.file(params[:relpath]) or return head :not_found
    @version = version

    if @file.kind == "binary" || @file.size > Reviews::FindingsFile::MAX_TEXT_BYTES || params[:raw].present?
      send_file @file.abspath, filename: File.basename(@file.relpath),
                type: "application/octet-stream", disposition: "attachment"
      return
    end

    @meta = version.metadata
    @versions = version.topic.versions
    @files = version.display_files
    prepare_content
  end

  private

  def prepare_content
    text = @file.read_text
    case @file.kind
    when "markdown"
      @content_html, @toc = helpers.render_markdown(text)
    when "patch"
      @content_html = helpers.diff_html(text)
      @toc = helpers.diff_toc(text)
    else
      @toc = []
      if @file.language && @file.size <= Reviews::Highlighter::MAX_BYTES
        @content_html = helpers.code_html(text, @file.language)
      end
      @plain_text = text unless @content_html
    end
  end
end
