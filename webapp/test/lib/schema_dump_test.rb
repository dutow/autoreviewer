require "test_helper"

class SchemaDumpTest < ActiveSupport::TestCase
  test "structure dump keeps fts table but strips its shadow tables" do
    dir = Dir.mktmpdir("dump")
    out = File.join(dir, "structure.sql")
    tasks = ActiveRecord::Tasks::SQLiteDatabaseTasks.new(ActiveRecord::Base.connection_db_config)
    tasks.structure_dump(out, nil)
    sql = File.read(out)
    assert_includes sql, "CREATE VIRTUAL TABLE documents_fts"
    refute_match(/^CREATE TABLE '?documents_fts_(?:data|idx|content|docsize|config)/, sql)
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
