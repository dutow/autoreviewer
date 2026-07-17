namespace :reindex do
  desc "Full reindex of the reviews tree into sqlite. " \
       "Avoid running while the server is up: it competes for the sqlite write lock " \
       "and can interleave with the live indexer."
  task full: :environment do
    Indexer.synchronized_run(full: true)
  end
end
