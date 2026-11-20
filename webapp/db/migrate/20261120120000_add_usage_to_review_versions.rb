class AddUsageToReviewVersions < ActiveRecord::Migration[8.1]
  def up
    add_column :review_versions, :cost_usd, :float
    add_column :review_versions, :total_tokens, :integer
    add_column :review_versions, :route, :string
    # force full reindex to fill the new columns
    execute "DELETE FROM index_states WHERE key = 'head'"
  end

  def down
    remove_column :review_versions, :route
    remove_column :review_versions, :total_tokens
    remove_column :review_versions, :cost_usd
  end
end
