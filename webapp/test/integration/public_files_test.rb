require "test_helper"

class PublicFilesBrowseTest < ActionDispatch::IntegrationTest
  setup do
    @reviews_dir = ReviewsFixture.create
    @old_root = ENV["REVIEWS_ROOT"]
    @old_auth = ENV["AUTH_MODE"]
    ENV["REVIEWS_ROOT"] = @reviews_dir
    @pub = File.join(@reviews_dir, "public")
    write("readme.txt", "hello")
    write("site/index.html", "<h1>site</h1>")
    write("site/app.css", "body{}")
    write("site/app.js", "1;")
    write("dl/blob.qqq", "\x00\x01\xffbin".b)
    write("dl/.hidden", "x")
    FileUtils.mkdir_p(File.join(@pub, "empty"))
    File.symlink("site", File.join(@pub, "alias"))
    File.write(File.join(@reviews_dir, "secret.html"), "<p>SECRET</p>")
    File.symlink(@reviews_dir, File.join(@pub, "escape"))
    ENV["AUTH_MODE"] = "none"
  end

  teardown do
    ENV["AUTH_MODE"] = @old_auth
    ENV["REVIEWS_ROOT"] = @old_root
    FileUtils.remove_entry(@reviews_dir)
  end

  def write(rel, content)
    abs = File.join(@pub, rel)
    FileUtils.mkdir_p(File.dirname(abs))
    File.binwrite(abs, content)
  end

  def listed_names
    css_select("table.listing tbody td:first-child a").map(&:text)
  end

  test "dir without trailing slash redirects, query kept" do
    get "/public"
    assert_redirected_to "/public/"
    get "/public/site"
    assert_redirected_to "/public/site/"
    get "/public/site?list=1"
    assert_redirected_to "/public/site/?list=1"
  end

  test "root listing: dirs first, hidden and escaping skipped" do
    get "/public/"
    assert_response :success
    assert_equal ["alias/", "dl/", "empty/", "site/", "readme.txt"], listed_names
    assert_select "table.listing td.num", text: "5 Bytes"
    assert_select "table.listing td.date", minimum: 1
    assert_select "nav.crumbs a[href=?]", "/public/"
  end

  test "nested listing has parent link and crumbs" do
    get "/public/dl/"
    assert_response :success
    assert_equal ["../", "blob.qqq"], listed_names
    assert_select "table.listing a[href=?]", "/public/"
    assert_select "table.listing a[href=?]", "/public/dl/blob.qqq"
    assert_select "nav.crumbs span", text: "dl"
  end

  test "empty dir" do
    get "/public/empty/"
    assert_response :success
    assert_select "p.empty", /nothing here/
  end

  test "index.html served, ?list=1 overrides" do
    get "/public/site/"
    assert_response :success
    assert_match %r{\Atext/html}, response.content_type
    assert_equal "<h1>site</h1>", response.body
    get "/public/site/?list=1"
    assert_response :success
    assert_equal ["../", "app.css", "app.js", "index.html"], listed_names
  end

  test "files served inline with mime by extension" do
    get "/public/site/app.css"
    assert_response :success
    assert_match %r{\Atext/css}, response.content_type
    assert_match(/\Ainline/, response.headers["content-disposition"])
    assert_equal "body{}", response.body

    get "/public/dl/blob.qqq"
    assert_response :success
    assert_equal "application/octet-stream", response.content_type
    assert_equal "\x00\x01\xffbin".b, response.body.b
  end

  test "conditional get" do
    get "/public/readme.txt"
    etag = response.headers["etag"]
    assert etag.present?
    get "/public/readme.txt", headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "bad paths are 404" do
    get "/public/dl/.hidden"
    assert_response :not_found
    get "/public/escape/secret.html"
    assert_response :not_found
    get "/public/nope.txt"
    assert_response :not_found
    get "/public/readme.txt/"
    assert_response :not_found
    get "/public/a%20b.txt"
    assert_response :not_found
  end

  test "escaping index.html is ignored" do
    FileUtils.mkdir_p(File.join(@pub, "leak"))
    File.symlink(File.join(@reviews_dir, "secret.html"), File.join(@pub, "leak/index.html"))
    get "/public/leak/"
    assert_response :success
    assert_equal ["../"], listed_names
    refute_includes response.body, "SECRET"
  end

  test "symlink inside root is followed" do
    get "/public/alias/"
    assert_response :success
    assert_equal "<h1>site</h1>", response.body
    get "/public/alias/?list=1"
    assert_response :success
    assert_equal ["../", "app.css", "app.js", "index.html"], listed_names
  end

  test "missing public dir is 404" do
    FileUtils.rm_rf(@pub)
    get "/public/"
    assert_response :not_found
  end

  test "login gate applies" do
    ENV.delete("AUTH_MODE")
    get "/public/"
    assert_response :unauthorized
    get "/public/readme.txt"
    assert_response :unauthorized
  end

  test "topbar links to files" do
    get "/"
    assert_select "header.topbar a[href=?]", "/public/", text: "Files"
  end
end
