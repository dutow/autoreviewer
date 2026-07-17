require "tmpdir"
require "fileutils"

ENV["RAILS_ENV"] ||= "test"
unless ENV["REVIEWS_ROOT"]
  reviews_empty = Dir.mktmpdir("reviews_empty")
  ENV["REVIEWS_ROOT"] = reviews_empty
  at_exit { FileUtils.remove_entry(reviews_empty, true) }
end
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/reviews_fixture"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    def with_reviews_root
      IndexState.delete_all # leaked state would silently switch indexer tests to the failed-diff path
      dir = ReviewsFixture.create
      yield ReviewsRoot.new(path: dir), dir
    ensure
      FileUtils.remove_entry(dir) if dir
    end
  end
end
