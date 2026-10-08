module PublicFilesHelper
  # dir urls carry a trailing slash so relative links in served html resolve
  def public_dir_path(segs)
    "#{public_file_path(relpath: segs.join("/"))}/"
  end
end
