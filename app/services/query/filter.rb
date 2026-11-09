# typed: strict
# frozen_string_literal: true

module Query
  # The filter language of the query bar:
  #
  #   app:hook status:error duration:>250 -path:/up route:/api/v1/wants* "timeout"
  #
  # Terms are ANDed. A term is `key:value`, negated with a leading `-`.
  # Values: a comma list is "any of" (`status:ok,error`); `*` is a wildcard;
  # `>`, `>=`, `<`, `<=` compare; `a..b` is a range; `key:*` means "is
  # present". `@key` reaches into a record's free-form attributes. A bare or
  # quoted word searches the source's text columns. Durations take a unit
  # (`250ms`, `1.5s`).
  #
  # This class only parses; what a key *means* is the compiler's business.
  module Filter
    extend T::Sig

    class Term < T::Struct
      # nil: a free-text term.
      const :key, T.nilable(String)
      # eq | gt | gte | lt | lte | range | present
      const :op, String
      const :values, T::Array[String]
      const :negated, T::Boolean
    end

    MAX_TERMS = 40
    KEY = /\A(-?)(@?[A-Za-z_][\w.\-]*):(.*)\z/m

    sig { params(text: T.nilable(String)).returns(T::Array[Term]) }
    def self.parse(text)
      tokens = tokenize(text.to_s)
      raise Invalid, "A filter may hold at most #{MAX_TERMS} terms" if tokens.size > MAX_TERMS

      tokens.map { |token| term(token) }
    end

    # `key:"value"`, written so `parse` reads `value` back whole — whatever
    # spaces, quotes, commas or backslashes it holds.
    sig { params(key: String, value: T.untyped).returns(String) }
    def self.quote(key, value) = quote_any(key, [ value ])

    # `key:value` when the value is a bare word (a slug, a kind), quoted as
    # in `quote` otherwise — the spelling a person would type.
    sig { params(key: String, value: T.untyped).returns(String) }
    def self.pair(key, value) = value.to_s.match?(/\A[\w.\/-]+\z/) ? "#{key}:#{value}" : quote(key, value)

    # `key:"a","b"`: any of the values, each quoted as in `quote`.
    sig { params(key: String, values: T::Array[T.untyped]).returns(String) }
    def self.quote_any(key, values) = "#{key}:" + values.map { |value| quote_text(value) }.join(",")

    # `"words"`: free text, searched whole, quoted as in `quote`.
    sig { params(text: T.untyped).returns(String) }
    def self.quote_text(text) = %("#{text.to_s.gsub(/["\\]/) { |char| "\\#{char}" }}")

    # Split on whitespace outside double quotes. A backslash escapes a quote
    # inside one; the escape is kept until the value is unquoted, so a list
    # of quoted values still splits where its commas are.
    sig { params(text: String).returns(T::Array[String]) }
    def self.tokenize(text)
      tokens = T.let([], T::Array[String])
      current = T.let(+"", String)
      quoted = T.let(false, T::Boolean)
      escaped = T.let(false, T::Boolean)
      text.each_char do |char|
        if escaped
          current << char
          escaped = false
        elsif char == "\\" && quoted
          current << char
          escaped = true
        elsif char == '"'
          quoted = !quoted
          current << char
        elsif char.match?(/\s/) && !quoted
          tokens << current unless current.empty?
          current = +""
        else
          current << char
        end
      end
      raise Invalid, "Unclosed quote in filter" if quoted

      tokens << current unless current.empty?
      tokens
    end
    private_class_method :tokenize

    sig { params(token: String).returns(Term) }
    def self.term(token)
      match = KEY.match(token)
      if match.nil? || token.start_with?('"')
        negated = token.start_with?("-") && token.length > 1
        return Term.new(key: nil, op: "eq", values: [ unquote(negated ? T.must(token[1..]) : token) ], negated: negated)
      end

      negated = match[1] == "-"
      key = T.must(match[2])
      rest = T.must(match[3])
      raise Invalid, "“#{key}:” needs a value" if rest.empty?

      op, values = operand(rest)
      Term.new(key: key, op: op, values: values, negated: negated)
    end
    private_class_method :term

    sig { params(rest: String).returns([ String, T::Array[String] ]) }
    def self.operand(rest)
      return [ "present", [] ] if rest == "*"

      { ">=" => "gte", "<=" => "lte", ">" => "gt", "<" => "lt" }.each do |prefix, op|
        return [ op, [ unquote(T.must(rest[prefix.length..])) ] ] if rest.start_with?(prefix)
      end
      if !rest.start_with?('"') && (range = rest.match(/\A([^.,]+(?:\.\d+)?[a-z]*)\.\.([^.,]+(?:\.\d+)?[a-z]*)\z/))
        return [ "range", [ T.must(range[1]), T.must(range[2]) ] ]
      end

      [ "eq", split_list(rest).map { |value| unquote(value) } ]
    end
    private_class_method :operand

    # Commas separate alternatives, except inside quotes.
    sig { params(text: String).returns(T::Array[String]) }
    def self.split_list(text)
      parts = T.let([], T::Array[String])
      current = T.let(+"", String)
      quoted = T.let(false, T::Boolean)
      escaped = T.let(false, T::Boolean)
      text.each_char do |char|
        if escaped
          escaped = false
        elsif char == "\\" && quoted
          escaped = true
        elsif char == '"'
          quoted = !quoted
        elsif char == "," && !quoted
          parts << current
          current = +""
          next
        end
        current << char
      end
      parts << current
      parts.reject(&:empty?)
    end
    private_class_method :split_list

    sig { params(value: String).returns(String) }
    def self.unquote(value)
      return value unless value.length >= 2 && value.start_with?('"') && value.end_with?('"')

      T.must(value[1..-2]).gsub(/\\(.)/m, '\\1')
    end
    private_class_method :unquote
  end
end
