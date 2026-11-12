class AddFindingCountsToReviewVersions < ActiveRecord::Migration[8.1]
  COLUMNS = %i[bug_count likely_bug_count suspicious_count risky_count nitpick_count typo_count
               post_count fyi_count withdrawn_count].freeze

  def up
    COLUMNS.each { |c| add_column :review_versions, c, :integer }
    # force full reindex to fill the new columns
    execute "DELETE FROM index_states WHERE key = 'head'"
  end

  def down
    COLUMNS.each { |c| remove_column :review_versions, c }
  end
end
