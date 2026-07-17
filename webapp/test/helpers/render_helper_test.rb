require "test_helper"

class RenderHelperTest < ActionView::TestCase
  include RenderHelper

  test "diff_html classifies file headers and deleted comment lines" do
    html = diff_html("--- a/foo.sql\n+++ b/foo.sql\n@@ -1,2 +1,1 @@\n--- old comment\n+new\n ctx\n")
    assert_includes html, %(<span class="diff-file">--- a/foo.sql\n</span>)
    assert_includes html, %(<span class="diff-file" id="d-file-1">+++ b/foo.sql\n</span>)
    assert_includes html, %(<span class="diff-del">--- old comment\n</span>)
    assert_includes html, %(<span class="diff-add">+new\n</span>)
    assert_includes diff_html("--- /dev/null\n"), %(<span class="diff-file">--- /dev/null\n</span>)
  end

  test "safe_url allows only http(s) with a host" do
    assert_equal "https://example.org/x", safe_url("https://example.org/x")
    assert_nil safe_url("javascript:alert(1)")
    assert_nil safe_url("http:foo")
    assert_nil safe_url("not a url")
    assert_nil safe_url(nil)
  end

  test "render_markdown emits heading anchor ids and toc" do
    html, toc = render_markdown("# One\n\n## Two: sub!\n\n#### Four\n")
    assert_includes html, %(id="one")
    assert_equal [{ level: 1, id: "one", text: "One" },
                  { level: 2, id: "two-sub", text: "Two: sub!" }], toc
  end

  test "render_markdown highlights known fence languages without inline styles" do
    html, = render_markdown("```sql\nSELECT 1;\n```\n")
    assert_includes html, %(class="highlight")
    assert_includes html, %(<span class="k">SELECT</span>)
    refute_includes html, "style="
  end

  test "render_markdown leaves unknown and bare fences plain" do
    html, = render_markdown("```zzz-no-such-lang\nproject('x')\n```\n\n```\nplain\n```\n")
    assert_includes html, %(<pre lang="zzz-no-such-lang"><code>project('x')\n</code></pre>)
    assert_includes html, "<pre><code>plain\n</code></pre>"
    refute_includes html, "style="
    refute_includes html, %(class="highlight")
  end

  test "code_html returns nil when language is unknown" do
    assert_nil code_html("x", "no-such-lang")
  end

  test "render_markdown keeps code html-escaped after highlighting" do
    html, = render_markdown("```c\nint a; // <script>alert(1)</script>\n```\n")
    refute_includes html, "<script>"
  end

  test "diff_html anchors file headers and diff_toc lists them" do
    text = "--- a/foo.sql\n+++ b/foo.sql\n@@ -1 +1 @@\n-a\n+b\n--- a/bar.c\n+++ b/bar.c\n"
    html = diff_html(text)
    assert_includes html, %(<span class="diff-file" id="d-file-1">+++ b/foo.sql\n</span>)
    assert_includes html, %(<span class="diff-file" id="d-file-2">+++ b/bar.c\n</span>)
    assert_equal [{ level: 1, id: "d-file-1", text: "foo.sql" },
                  { level: 1, id: "d-file-2", text: "bar.c" }],
                 diff_toc(text)
  end
end
