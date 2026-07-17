class Indexer
  CHECK_INTERVAL = 15 # seconds between HEAD checks via the request fallback

  MUTEX = Mutex.new
  @last_check = Time.at(0)

  class << self
    # Cheap fallback callable from requests: throttled, work in a thread.
    def run_if_stale
      return if Time.now - @last_check < CHECK_INTERVAL

      @last_check = Time.now
      Thread.new { Rails.application.executor.wrap { synchronized_run } }
    end

    def synchronized_run(full: false)
      MUTEX.synchronize { new.run(full: full) }
    rescue => e
      Rails.logger.error("indexer: #{e.class}: #{e.message}")
    end
  end

  def initialize(root: ReviewsRoot.new)
    @root = root
  end

  def run(full: false)
    head = @root.git_head
    return if head.nil?

    last = IndexState.get("head")
    return if !full && head == last

    changed = (!full && last) ? changed_version_keys(last, head) : nil
    changed ? reindex_keys(changed) : full_reindex
    IndexState.set("head", head)
    Rails.logger.info("indexer: indexed #{head}#{changed ? " (#{changed.size} dirs)" : " (full)"}")
  end

  private

  def changed_version_keys(old, new)
    out, status = @root.git("diff", "--name-only", "--no-renames", "#{old}..#{new}")
    return nil unless status.success? # e.g. force push, gc'd sha -> full reindex

    out.lines.filter_map { |l|
      m = l.match(%r{\A([^/]+)/findings/([^/]+)/v(\d+)/})
      [m[1], m[2], m[3].to_i] if m
    }.uniq
  end

  def reindex_keys(keys)
    keys.each do |project, topic, version|
      v = @root.project(project)&.topic(topic)&.version(version)
      v ? index_version(v) : remove_version(project, topic, version)
    end
  end

  def full_reindex
    seen = []
    @root.projects.each do |proj|
      proj.topics.each do |topic|
        topic.versions.each do |v|
          index_version(v)
          seen << [proj.name, topic.name, v.number]
        end
      end
    end
    existing = ReviewVersion.pluck(:project, :topic, :version)
    (existing - seen).each { |p, t, n| remove_version(p, t, n) }
    # cross-process interleaving (rake reindex:full vs live server) can strand fts rows
    Document.connection.execute("DELETE FROM documents_fts WHERE rowid NOT IN (SELECT id FROM documents)")
  end

  def index_version(v)
    ApplicationRecord.transaction do
      meta = v.metadata
      rv = ReviewVersion.find_or_initialize_by(project: v.project_name, topic: v.topic_name, version: v.number)
      rv.assign_attributes(
        title: meta["title"] || fallback_title(v),
        source_url: meta["source_url"],
        hackorum_url: meta["hackorum_url"],
        reviewed_at: parse_time(meta["reviewed_at"]) || git_time(v.relpath),
        path: v.relpath
      )
      rv.save! if rv.changed?

      old_ids = rv.documents.pluck(:id)
      Document.fts_delete(old_ids)
      rv.documents.delete_all(:delete_all) # dependent: nil means delete_all would nullify instead of delete
      v.files.each do |f|
        next unless f.indexable?

        doc = Document.create!(review_version: rv, relpath: f.relpath, kind: f.kind)
        Document.fts_insert(doc.id, f.read_text)
      end
    end
  rescue Errno::ENOENT, Errno::ENOTDIR => e
    # dir vanished mid-walk: whole transaction rolls back, old docs stay; heals on next HEAD change
    Rails.logger.warn("indexer: skipped #{v.relpath}: #{e.message}")
  end

  def remove_version(project, topic, version)
    rv = ReviewVersion.find_by(project: project, topic: topic, version: version)
    return unless rv

    ApplicationRecord.transaction do
      Document.fts_delete(rv.documents.pluck(:id))
      rv.documents.delete_all(:delete_all) # dependent: nil means delete_all would nullify instead of delete
      rv.destroy!
    end
  end

  def fallback_title(v)
    overview = File.join(v.dir, "00-overview.md")
    return nil unless File.exist?(overview)

    File.foreach(overview) do |line|
      next unless line =~ /\A#\s+(.+)/

      heading = Regexp.last_match(1).strip
      return heading =~ /\A(Patch|PR) Overview/ ? nil : heading
    end
    nil
  end

  def git_time(relpath)
    out, status = @root.git("log", "-1", "--format=%cI", "--", relpath)
    status.success? && !out.strip.empty? ? Time.iso8601(out.strip) : nil
  end

  def parse_time(str)
    str && Time.iso8601(str)
  rescue ArgumentError
    nil
  end
end
