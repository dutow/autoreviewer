# Periodic reindex, independent of traffic. Registered via the server hook so
# it runs ONLY in a web-server process -- never in console, rake, db:prepare
# (docker entrypoint) or assets:precompile (docker build).
Rails.application.server do
  interval = Integer(ENV["REINDEX_INTERVAL"].presence || 60)
  timer = Concurrent::TimerTask.new(execution_interval: interval, run_now: true) do
    Rails.application.executor.wrap { Indexer.synchronized_run }
  end
  timer.execute
end
