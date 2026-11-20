require 'minitest/autorun'
require 'json'

require_relative '../../lib/review_run/stream'

# Fixture is synthetic (hand-written); replace with a real CLI capture.
class StreamTest < Minitest::Test
  FIXTURE = File.expand_path('../fixtures/review_run/stream-sample.jsonl', __dir__)

  def fmt(h)
    ReviewRun::Stream.format_event(JSON.parse(JSON.generate(h)))
  end

  def result(text, is_error: true)
    ReviewRun::Result.from_event('type' => 'result', 'is_error' => is_error, 'result' => text)
  end

  def test_parse_line_ignores_garbage
    assert_nil ReviewRun::Stream.parse_line('not json')
    assert_nil ReviewRun::Stream.parse_line('')
    assert_nil ReviewRun::Stream.parse_line('{"type":"res')
  end

  def test_format_tool_use_bash
    ev = { type: 'assistant', parent_tool_use_id: nil,
           message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'echo hi' } }] } }
    assert_equal '-> Bash: echo hi', fmt(ev)
  end

  def test_format_subagent_prefix
    ev = { type: 'assistant', parent_tool_use_id: 'toolu_9',
           message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: '/a/b' } }] } }
    assert_equal '  [sub] -> Read: /a/b', fmt(ev)
  end

  def test_format_result_line
    ev = { type: 'result', subtype: 'success', num_turns: 3, total_cost_usd: 0.1234, duration_ms: 4500 }
    assert_equal '== result: success, 3 turns, $0.12, 4.5s', fmt(ev)
  end

  def test_format_init_and_error
    assert_equal '== session s1 (m1)', fmt(type: 'system', subtype: 'init', session_id: 's1', model: 'm1')
    ev = { type: 'user', message: { content: [{ type: 'tool_result', is_error: true, content: "bad\nmore" }] } }
    assert_equal '!! bad', fmt(ev)
  end

  def test_result_from_fixture
    ev = ReviewRun::Stream.parse_line(File.readlines(FIXTURE).last)
    r = ReviewRun::Result.from_event(ev)
    assert_equal 2, r.num_turns
    assert_equal '11111111-2222-3333-4444-555555555555', r.session_id
    assert_equal 57, r.tokens['output']
    assert_equal 8192, r.models['claude-haiku-5-5']['cache_read']
    assert_operator r.cost_usd, :>, 0
    assert_equal 'ok', r.text
    refute r.limit_hit?
  end

  def test_limit_hit
    assert result('Claude AI usage limit reached|1800000000').limit_hit?
    refute result('usage limit', is_error: false).limit_hit?
  end

  def test_limit_reset_epoch
    r = result('Claude AI usage limit reached|1800000000')
    assert_equal Time.at(1800000000), r.limit_reset(Time.now)
  end

  def test_limit_reset_clock
    now = Time.local(2026, 11, 20, 13, 0, 0)
    assert_equal Time.local(2026, 11, 20, 15, 0, 0), result('limit reached, resets 3pm').limit_reset(now)
    assert_equal Time.local(2026, 11, 21, 9, 30, 0), result('limit reached, resets at 9:30am').limit_reset(now)
  end

  def test_limit_reset_default
    now = Time.local(2026, 11, 20, 13, 0, 0)
    assert_equal now + 3600, result('usage limit').limit_reset(now)
  end
end
