# frozen_string_literal: true

module Glass
  # SQL normalization: the statement shape with every literal removed, so a
  # span's `res` can never carry a value (protocol rule 7) and the same
  # query from a thousand requests folds into one row on the Queries page.
  module Sql
    MAX_LENGTH = 4_000
    # Statements past this are cut before any regex work: a bulk insert of
    # a few thousand rows is not worth scanning on a request thread.
    MAX_INPUT = 20_000
    CACHE_MAX = 1_000

    COMMENT = %r{/\*.*?\*/|--[^\n]*}m
    # Standard single-quoted strings ('' escapes), E'' strings with
    # backslash escapes, and dollar-quoted strings.
    STRING = /E'(?:[^'\\]|\\.|'')*'|'(?:[^']|'')*'|\$(\w*)\$.*?\$\1\$/m
    # Bind placeholders ($1, :name) and numbers not glued to an identifier
    # or a quoted name.
    BIND = /\$\d+|(?<![\w:]):[a-zA-Z_]\w*/
    NUMBER = /(?<![\w.$"'])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/
    IN_LIST = /\bIN\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/i
    TUPLE = /\((?:\s*\?\s*,?)+\)/
    TUPLE_LIST = /(#{TUPLE})(?:\s*,\s*#{TUPLE})+/
    WHITESPACE = /\s+/

    @cache = BoundedCache.new(CACHE_MAX)

    class << self
      # Memoized per raw statement: prepared statements (the Postgres
      # default) repeat byte for byte, so almost every call is a hash hit.
      # The cache is cleared, not evicted, when full — cheap and bounded.
      def normalize(sql)
        return "" if sql.nil?
        @cache.fetch(sql) { normalize_uncached(sql) }
      end

      def normalize_uncached(sql)
        s = sql.to_s
        s = s.byteslice(0, MAX_INPUT).scrub if s.bytesize > MAX_INPUT
        s = s.gsub(COMMENT, " ")
        s = s.gsub(STRING, "?")
        s = s.gsub(BIND, "?")
        s = s.gsub(NUMBER, "?")
        s = s.gsub(IN_LIST, "IN (?)")
        s = s.gsub(TUPLE_LIST, '\1')
        s = s.gsub(WHITESPACE, " ").strip
        s.size > MAX_LENGTH ? s[0, MAX_LENGTH] : s
      end

      # "SELECT wants" from a normalized statement: the first verb and the
      # table it acts on. Used when Active Record gave the query no name.
      def label(normalized)
        verb = normalized[/\A\s*([a-zA-Z]+)/, 1]
        return "SQL" unless verb
        verb = verb.upcase
        table =
          case verb
          when "INSERT" then normalized[/\bINTO\s+["`]?([\w.]+)/i, 1]
          when "UPDATE" then normalized[/\AUPDATE\s+(?:ONLY\s+)?["`]?([\w.]+)/i, 1]
          when "SELECT", "DELETE" then normalized[/\bFROM\s+(?:ONLY\s+)?["`]?([\w.]+)/i, 1]
          end
        table ? "#{verb} #{table}" : verb
      end

      def reset!
        @cache.clear
      end
    end
  end
end
