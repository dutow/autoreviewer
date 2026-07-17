module Reviews
  module Highlighter
    MAX_BYTES = 512 * 1024

    # fence languages in the corpus that rouge knows under another name
    ALIASES = { "sgml" => "xml", "pl" => "perl" }.freeze

    def self.html(text, language)
      lang = ALIASES.fetch(language.to_s, language.to_s)
      lexer = Rouge::Lexer.find(lang) or return nil
      Rouge::Formatters::HTML.new.format(lexer.lex(text))
    rescue StandardError
      nil
    end
  end
end
