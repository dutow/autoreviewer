require 'minitest/autorun'
require 'json'
require 'open3'

class WorkspaceHooksTest < Minitest::Test
  SETTINGS = File.expand_path('../examples/workspace/.claude/settings.json', __dir__)

  def hook(event)
    JSON.parse(File.read(SETTINGS)).dig('hooks', event, 0, 'hooks', 0, 'command')
  end

  def run_hook(event, env)
    out, st = Open3.capture2({ 'REVIEW_RUN' => nil, 'REVIEW_DONE_FILE' => nil }.merge(env), 'sh', '-c', hook(event),
                             stdin_data: '{}')
    assert st.success?
    out
  end

  def test_permission_request_allows_in_review_sessions
    [{ 'REVIEW_RUN' => '1' }, { 'REVIEW_DONE_FILE' => '/nonexistent/done' }].each do |env|
      out = run_hook('PermissionRequest', env)
      assert_equal({ 'behavior' => 'allow' }, JSON.parse(out).dig('hookSpecificOutput', 'decision'), env.inspect)
    end
  end

  def test_permission_request_silent_elsewhere
    assert_empty run_hook('PermissionRequest', {})
  end

  def test_stop_hook_guarded_on_done_file_only
    assert hook('Stop').start_with?('[ -n "$REVIEW_DONE_FILE" ] || exit 0;')
    assert_empty run_hook('Stop', 'REVIEW_RUN' => '1')
  end
end
