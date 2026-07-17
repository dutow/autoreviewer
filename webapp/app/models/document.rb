class Document < ApplicationRecord
  belongs_to :review_version

  # Snippet sentinels: control chars that cannot occur in indexed text.
  # View-layer contract: escape the snippet HTML first, THEN convert
  # MARK_START -> <mark> and MARK_END -> </mark>.
  MARK_START = "\u0001"
  MARK_END = "\u0002"

  # FTS5 search; returns [{document:, snippet:}] ranked by bm25.
  def self.search(query)
    terms = query.to_s.scan(/\S+/).first(8).map { |t| %("#{t.gsub('"', '""')}") }
    return [] if terms.empty?

    rows = connection.select_all(sanitize_sql_array([<<~SQL, terms.join(" ")]))
      SELECT rowid, snippet(documents_fts, 0, char(1), char(2), ' … ', 16) AS snip
      FROM documents_fts WHERE documents_fts MATCH ?
      ORDER BY bm25(documents_fts) LIMIT 50
    SQL
    docs = includes(:review_version).where(id: rows.map { |r| r["rowid"] }).index_by(&:id)
    rows.filter_map { |r| { document: docs[r["rowid"]], snippet: r["snip"] } if docs[r["rowid"]] }
  end

  def self.fts_insert(id, content)
    connection.execute(sanitize_sql_array(
      ["INSERT INTO documents_fts(rowid, content) VALUES (?, ?)", id, content]
    ))
  end

  def self.fts_delete(ids)
    return if ids.empty?

    connection.execute("DELETE FROM documents_fts WHERE rowid IN (#{ids.map(&:to_i).join(',')})")
  end
end
