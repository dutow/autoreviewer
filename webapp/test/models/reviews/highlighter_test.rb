require "test_helper"

class Reviews::HighlighterTest < ActiveSupport::TestCase
  test "highlights known languages with token classes" do
    html = Reviews::Highlighter.html("SELECT 1;", "sql")
    assert_includes html, %(<span class="k">SELECT</span>)
  end

  test "returns nil for unknown or blank language" do
    assert_nil Reviews::Highlighter.html("foo()", "not-a-real-language")
    assert_nil Reviews::Highlighter.html("foo()", nil)
    assert_nil Reviews::Highlighter.html("foo()", "")
  end

  test "maps corpus aliases" do
    assert Reviews::Highlighter.html("<a>x</a>", "sgml")
    assert Reviews::Highlighter.html("my $x = 1;", "pl")
  end

  test "escapes html in code" do
    html = Reviews::Highlighter.html(%(int a; // <script>alert(1)</script>), "c")
    refute_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  end
end
