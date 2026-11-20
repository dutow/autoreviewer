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

  DOT = "\u00b7".freeze

  def test_limit_hit_real_texts
    ["You've hit your 5-hour limit #{DOT} resets 3pm (Europe/Budapest)",
     "You've hit your weekly limit. It resets Nov 24, 3pm.",
     "You've hit your Opus limit #{DOT} resets Nov 24, 3pm (Europe/Budapest)",
     "You've hit your limit #{DOT} resets 3:30pm (Europe/Budapest)"].each do |t|
      assert result(t).limit_hit?, t
    end
    refute result("You've hit your 5-hour limit", is_error: false).limit_hit?
  end

  def test_limit_false_positives
    ['Server is temporarily limiting requests (not your usage limit)',
     "Context limit reached #{DOT} /compact or /clear to continue",
     'Claude AI usage limit reached|1800000000',
     'API Error: 500'].each do |t|
      refute result(t).limit_hit?, t
    end
  end

  def test_limit_reset_clock
    now = Time.local(2026, 11, 20, 13, 0, 0)
    assert_equal Time.local(2026, 11, 20, 15, 0, 0),
                 result("You've hit your 5-hour limit #{DOT} resets 3pm (Europe/Budapest)").limit_reset(now)
    assert_equal Time.local(2026, 11, 20, 15, 30, 0), result("You've hit your limit #{DOT} resets 3:30pm").limit_reset(now)
    assert_equal Time.local(2026, 11, 21, 9, 0, 0), result("You've hit your limit. It resets 9am.").limit_reset(now)
    assert_equal Time.local(2026, 11, 21, 9, 30, 0), result('limit, resets at 9:30am').limit_reset(now)
  end

  def test_limit_reset_date
    now = Time.local(2026, 11, 20, 13, 0, 0)
    assert_equal Time.local(2026, 11, 24, 15, 0, 0),
                 result("You've hit your weekly limit #{DOT} resets Nov 24, 3pm (Europe/Budapest)").limit_reset(now)
    assert_equal Time.local(2026, 11, 24, 15, 30, 0),
                 result("You've hit your weekly limit. It resets Nov 24, 3:30pm.").limit_reset(now)
    assert_equal Time.local(2027, 1, 2, 8, 0, 0), result("You've hit your limit #{DOT} resets Jan 2, 8am").limit_reset(now)
    assert_equal Time.local(2027, 11, 24, 15, 0, 0),
                 result("You've hit your limit #{DOT} resets Nov 24, 2027, 3pm").limit_reset(now)
  end

  def test_limit_reset_default
    now = Time.local(2026, 11, 20, 13, 0, 0)
    assert_equal now + 3600, result("You've hit your limit").limit_reset(now)
  end

  def test_limit_reset_bad_time_raises
    assert_raises(ArgumentError) { result("You've hit your limit #{DOT} resets 3:75pm").limit_reset(Time.now) }
  end

  def rl_event(info)
    { 'type' => 'rate_limit_event', 'rate_limit_info' => info, 'session_id' => 's' }
  end

  def test_rate_limit_from_event
    rl = ReviewRun::RateLimit.from_event(rl_event('status' => 'rejected', 'resetsAt' => 1_800_000_000,
                                                  'rateLimitType' => 'five_hour'))
    assert rl.rejected?
    assert_equal Time.at(1_800_000_000), rl.resets_at
    assert_equal 'five_hour', rl.type
    refute ReviewRun::RateLimit.from_event(rl_event('status' => 'allowed_warning')).rejected?
    assert_nil ReviewRun::RateLimit.from_event(rl_event('status' => 'rejected')).resets_at
    assert_nil ReviewRun::RateLimit.from_event(rl_event(nil))
    assert_nil ReviewRun::RateLimit.from_event('type' => 'result')
  end

  def test_format_rate_limit_event
    assert_nil fmt(rl_event('status' => 'allowed'))
    line = fmt(rl_event('status' => 'rejected', 'resetsAt' => 1_800_000_000, 'rateLimitType' => 'five_hour'))
    assert_match(/\A== rate limit rejected \(five_hour\), resets \d{4}-\d\d-\d\d \d\d:\d\d\z/, line)
  end
end
