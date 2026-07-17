# fts5 virtual tables create shadow tables that sqlite recreates itself;
# dumping them into structure.sql makes db:schema:load fail (reserved names).
# connection.data_sources doesn't list shadow tables, so the normal
# ignore_tables intersection (used by Rails' own structure_dump) never
# matches them - strip the dump lines directly instead.
module FtsShadowTableStrip
  SHADOW_RE = /\ACREATE TABLE ['"]?\w+_fts_(?:data|idx|content|docsize|config)['"]?\(/

  def structure_dump(filename, extra_flags)
    super
    return unless File.exist?(filename)

    File.write(filename, File.readlines(filename).reject { |l| l =~ SHADOW_RE }.join)
  end
end

ActiveRecord::Tasks::SQLiteDatabaseTasks.prepend(FtsShadowTableStrip)
