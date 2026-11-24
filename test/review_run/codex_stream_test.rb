require 'minitest/autorun'
require 'json'

require_relative '../../lib/review_run/codex_stream'

class CodexStreamTest < Minitest::Test
  def fixture(name)
    File.expand_path("../fixtures/review_run/#{name}", __dir__)
  end

  def events(name)
    File.readlines(fixture(name)).map { |l| JSON.parse(l) }
  end

  def result(name)
    ReviewRun::CodexResult.new(events(name), model: 'gpt-x', duration_ms: 5)
  end

  def limit_result(text)
    evs = [{ 'type' => 'thread.started', 'thread_id' => 't' },
           { 'type' => 'error', 'message' => text },
           { 'type' => 'turn.failed', 'error' => { 'message' => text } }]
    ReviewRun::CodexResult.new(evs, model: 'gpt-x', duration_ms: 5)
  end

  def usage_limit(tail)
    "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or #{tail}"
  end

  def test_success_sample
    r = result('codex-sample.jsonl')
    refute r.is_error
    assert_equal 'success', r.subtype
    assert_equal '01a20e84-deac-7b82-9dcf-f015eed6b591', r.session_id
    assert_equal({ 'input' => 16_467, 'output' => 50, 'cache_read' => 16_256, 'cache_write' => 0 }, r.tokens)
    assert_nil r.cost_usd
    assert_equal 'done', r.text
    assert_equal 3, r.num_turns
    assert_equal 5, r.duration_ms
    assert_equal({ 'gpt-x' => r.tokens.merge('cost_usd' => nil) }, r.models)
  end

  def test_error_sample
    r = result('codex-error.jsonl')
    assert r.is_error
    assert_equal 'error', r.subtype
    assert_match(/not supported/, r.text)
    refute r.limit_hit?
  end

  def test_limit_and_reset
    now = Time.local(2026, 11, 24, 14, 0)
    r = limit_result(usage_limit('try again at 3:05 PM.'))
    assert r.limit_hit?
    assert_equal Time.local(2026, 11, 24, 15, 5), r.limit_reset(now)
    assert_equal Time.local(2026, 11, 25, 9, 0), limit_result(usage_limit('try again at 9:00 AM.')).limit_reset(now)
    assert_equal Time.local(2026, 11, 27, 9, 0),
                 limit_result(usage_limit('try again at Nov 27th, 2026 9:00 AM.')).limit_reset(now)
    assert_equal now + (3 * 86_400), limit_result(usage_limit('try again in 3 days.')).limit_reset(now)
    assert_equal now + 3600, limit_result("You've hit your usage limit.").limit_reset(now)
  end

  def test_context_limit_is_not_usage_limit
    refute limit_result('usage limit of the context window').limit_hit?
  end

  def test_no_turn_completed_is_error
    r = ReviewRun::CodexResult.new([{ 'type' => 'thread.started', 'thread_id' => 't' }], model: 'm', duration_ms: 1)
    assert r.is_error
  end

  def test_format
    lines = events('codex-sample.jsonl').filter_map { |e| ReviewRun::CodexStream.format_event(e) }
    assert_includes lines, '== thread 01a20e84-deac-7b82-9dcf-f015eed6b591'
    assert(lines.any? { |l| l.start_with?('-> shell: /usr/bin/zsh') })
    assert_includes lines, 'done'
    assert_includes lines, '== result: ok, 32773 tokens'
  end

  def test_format_failures
    lines = events('codex-error.jsonl').filter_map { |e| ReviewRun::CodexStream.format_event(e) }
    assert(lines.any? { |l| l.start_with?('!! Model metadata') })
    assert(lines.any? { |l| l.start_with?('== result: failed: The') })
    ev = { 'type' => 'item.completed', 'item' => { 'type' => 'command_execution', 'exit_code' => 2 } }
    assert_equal '!! exit 2', ReviewRun::CodexStream.format_event(ev)
    ev = { 'type' => 'item.completed',
           'item' => { 'type' => 'file_change', 'changes' => [{ 'path' => 'a' }, { 'path' => 'b' }] } }
    assert_equal '-> edit: a, b', ReviewRun::CodexStream.format_event(ev)
    bare = { 'type' => 'item.completed', 'item' => { 'type' => 'file_change' } }
    assert_equal '-> edit: ', ReviewRun::CodexStream.format_event(bare)
  end
end
