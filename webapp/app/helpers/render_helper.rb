module RenderHelper
  # metadata.json comes from the reviews workspace; only link http(s) URLs
  def safe_url(url)
    uri = URI.parse(url.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present? ? url : nil
  rescue URI::InvalidURIError
    nil
  end

  # One parse does both jobs: pull the toc out of the rendered html and swap
  # fence contents for rouge markup. Commonmarker puts the heading id on the
  # empty a.anchor child, not the heading tag itself, so we read it back out
  # of the rendered html. Commonmarker's own highlighter is disabled — it
  # hardcodes inline styles for a single dark theme.
  def render_markdown(text)
    html = Commonmarker.to_html(text, options: {
      extension: { table: true, strikethrough: true, autolink: true, header_ids: "" }
    }, plugins: { syntax_highlighter: nil })
    doc = Nokogiri::HTML5.fragment(html)
    toc = doc.css("h1, h2, h3").filter_map do |h|
      id = h.at_css("a.anchor")&.[]("id")
      { level: h.name[1].to_i, id: id, text: h.text.strip } if id
    end
    doc.css("pre[lang] > code").each do |code|
      highlighted = Reviews::Highlighter.html(code.text, code.parent["lang"]) or next
      code.inner_html = highlighted
      code.parent.add_class("highlight")
    end
    [doc.to_html.html_safe, toc]
  end

  def code_html(text, language)
    body = Reviews::Highlighter.html(text, language) or return nil
    %(<pre class="highlight"><code>#{body}</code></pre>).html_safe
  end

  def diff_toc(text)
    text.each_line.grep(/\A\+\+\+ /).each_with_index.map do |line, i|
      name = line.chomp.delete_prefix("+++ ").sub(%r{\Ab/}, "")
      { level: 1, id: "d-file-#{i + 1}", text: name }
    end
  end

  # Escape first, then swap the indexer's control-char sentinels for <mark> tags.
  # SafeBuffer#gsub demotes the result to a plain (non-html_safe) String, so
  # force it back to a String with to_str before gsub, then mark it safe once.
  def snippet_html(snippet)
    escaped = ERB::Util.html_escape(snippet).to_str
    escaped.gsub(Document::MARK_START, "<mark>")
           .gsub(Document::MARK_END, "</mark>")
           .html_safe
  end

  def diff_html(text)
    file_no = 0
    lines = text.each_line.map do |line|
      cls = case line
            when %r{\A(\+\+\+|---) (a/|b/|/dev/null)} then "diff-file"
            when /\A@@/ then "diff-hunk"
            when /\A\+/ then "diff-add"
            when /\A-/ then "diff-del"
            else "diff-ctx"
            end
      id = line.start_with?("+++ ") ? %( id="d-file-#{file_no += 1}") : ""
      %(<span class="#{cls}"#{id}>#{ERB::Util.html_escape(line)}</span>)
    end
    %(<pre class="diff">#{lines.join}</pre>).html_safe
  end
end
