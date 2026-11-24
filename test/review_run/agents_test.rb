require 'minitest/autorun'

require_relative '../../lib/review_run/manifest'
require_relative '../../lib/review_run/agents'

class AgentsTest < Minitest::Test
  def cfg(review = nil, route: 'single', **opts)
    ReviewRun::Agents::Config.from_project({ 'review' => review || opts }, route: route)
  end

  def phase(**kw)
    ReviewRun::Phase.new(**kw)
  end

  def pick(topic, current:, previous:, paused:)
    ReviewRun::Agents.pick_alternate(topic: topic, current: current, previous: previous, paused: paused)
  end

  def test_defaults
    c = cfg({})
    assert_equal %w[claude claude codex], [c.mode, c.primary, c.secondary]
    assert_equal 'opus', c.model('claude', phase(model: 'opus'))
    assert_equal 'gpt-6.2-astra', c.model('codex', phase(model: 'opus'))
    assert_equal 'xhigh', c.effort('codex', phase)
  end

  def test_project_overrides_phase
    c = cfg('agent' => 'codex', 'claude' => { 'model' => 'sonnet', 'effort' => 'high' },
            'codex' => { 'model' => 'gpt-6-astra', 'effort' => 'max' })
    assert_equal 'sonnet', c.model('claude', phase(model: 'opus'))
    assert_equal 'high', c.effort('claude', phase(effort: 'low'))
    assert_equal %w[gpt-6-astra max], [c.model('codex', phase), c.effort('codex', phase)]
  end

  def test_bad_config
    assert_raises(ReviewRun::Agents::ConfigError) { cfg('agent' => 'gemini') }
    assert_raises(ReviewRun::Agents::ConfigError) { cfg('agent' => 'both', 'primary' => 'x') }
    assert_raises(ReviewRun::Agents::ConfigError) { cfg({ 'agent' => 'both' }, route: 'full') }
    assert_equal 'both', cfg({ 'agent' => 'both' }, route: nil).mode
    assert_raises(ReviewRun::Agents::ConfigError) { cfg({ 'agent' => 'gemini' }, route: nil) }
  end

  def test_error_names_key
    e = assert_raises(ReviewRun::Agents::ConfigError) { cfg('agent' => 'gemini') }
    assert_includes e.message, 'review.agent'
    e = assert_raises(ReviewRun::Agents::ConfigError) { cfg('primary' => 'x') }
    assert_includes e.message, 'review.primary'
  end

  def test_parity
    assert_equal 'claude', ReviewRun::Agents.parity('t139284')
    assert_equal 'codex', ReviewRun::Agents.parity('pr601')
    assert_includes %w[claude codex], ReviewRun::Agents.parity('abc')
    assert_equal ReviewRun::Agents.parity('abc'), ReviewRun::Agents.parity('abc')
  end

  def test_pick_alternate
    none = ->(_) { false }
    assert_equal 'codex', pick('t2', current: 'codex', previous: 'codex', paused: none)
    assert_equal 'codex', pick('t2', current: nil, previous: 'claude', paused: none)
    assert_equal 'claude', pick('t2', current: nil, previous: nil, paused: none)
    assert_equal 'codex', pick('t2', current: nil, previous: nil, paused: ->(a) { a == 'claude' })
    assert_equal 'claude', pick('t2', current: nil, previous: nil, paused: ->(_) { true })
  end

  def test_held
    h = ->(mode, c, x) { ReviewRun::Agents.held?(mode, 'claude' => c, 'codex' => x) }
    assert h.('claude', :short, :none)
    refute h.('claude', :none, :long)
    assert h.('codex', :none, :long)
    refute h.('alternate', :long, :none)
    assert h.('alternate', :short, :long)
    assert h.('both', :none, :short)
    refute h.('both', :long, :none)
    assert h.('both', :long, :long)
  end
end
