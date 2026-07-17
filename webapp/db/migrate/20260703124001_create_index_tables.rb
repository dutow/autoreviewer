class CreateIndexTables < ActiveRecord::Migration[8.1]
  def up
    create_table :review_versions do |t|
      t.string :project, null: false
      t.string :topic, null: false
      t.integer :version, null: false
      t.string :title
      t.string :source_url
      t.string :hackorum_url
      t.datetime :reviewed_at
      t.string :path, null: false
      t.timestamps
    end
    add_index :review_versions, %i[project topic version], unique: true
    add_index :review_versions, :reviewed_at

    create_table :documents do |t|
      t.references :review_version, null: false, foreign_key: true
      t.string :relpath, null: false
      t.string :kind, null: false
      t.timestamps
    end
    add_index :documents, %i[review_version_id relpath], unique: true

    create_table :index_states do |t|
      t.string :key, null: false
      t.string :value
      t.timestamps
    end
    add_index :index_states, :key, unique: true

    execute "CREATE VIRTUAL TABLE documents_fts USING fts5(content, tokenize = 'porter unicode61')"
  end

  def down
    execute "DROP TABLE documents_fts"
    drop_table :documents
    drop_table :index_states
    drop_table :review_versions
  end
end
