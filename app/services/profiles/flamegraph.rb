# typed: strict
# frozen_string_literal: true

module Profiles
  # A flamegraph for a filter and a range: sum the sampled
  # time of every stack that matches, look the stacks up, and merge them
  # into one call tree.
  #
  # With `baseline` it is a diff: the same tree built from two ranges at
  # once, each node carrying both weights, so the console can colour a frame
  # by how its share changed.
  #
  # The answer is columnar and preorder — `nodes` rows are
  # [function index, parent node index, self ms, total ms] (plus the
  # baseline's self and total in a diff) — because a busy app's tree is tens
  # of thousands of nodes and the console draws it on a canvas.
  class Flamegraph
    extend T::Sig

    # Stacks past this many (by weight) are folded into one "(other)" frame:
    # the tail of a profile is thousands of stacks seen once each.
    MAX_STACKS = 20_000
    # Nodes lighter than this share of the total are pruned into their
    # parent's "(other)" child — they would be narrower than a pixel.
    MIN_SHARE = 0.0002
    # The widest range a profile may be asked over.
    MAX_RANGE = T.let(100.days, ActiveSupport::Duration)

    class Range < T::Struct
      const :from, Time
      const :to, Time
      const :filter, String
    end

    # A node of the merged tree, under construction.
    class Node
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :function

      sig { returns(T::Hash[Integer, Node]) }
      attr_reader :children

      sig { returns(T::Array[Float]) }
      attr_reader :self_ms, :total_ms

      sig { params(function: Integer, sides: Integer).void }
      def initialize(function, sides)
        @function = function
        @children = T.let({}, T::Hash[Integer, Node])
        @self_ms = T.let(Array.new(sides, 0.0), T::Array[Float])
        @total_ms = T.let(Array.new(sides, 0.0), T::Array[Float])
      end
    end

    # Synthetic functions: the root every stack hangs from, and the frame
    # that stands for what was pruned.
    ROOT = 0
    OTHER = -1

    sig { params(context: Query::Context, range: Range, baseline: T.nilable(Range)).void }
    def initialize(context:, range:, baseline: nil)
      @context = context
      @ranges = T.let([ range, baseline ].compact, T::Array[Range])
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def build
      sides = @ranges.size
      weighed = @ranges.map { |range| weigh(range) }
      frames = stack_frames(weighed.flat_map { |weights| weights.by_stack.keys }.uniq)

      root = Node.new(ROOT, sides)
      weighed.each_with_index do |weights, side|
        weights.by_stack.each do |stack_id, ms|
          path = frames[stack_id] || [ OTHER ]
          add(root, path, ms, side)
        end
      end

      totals = root.total_ms
      functions, index_of = function_table(root)
      nodes = T.let([], T::Array[T::Array[T.untyped]])
      flatten(root, -1, totals, index_of, nodes)

      {
        total_ms: totals[0], baseline_total_ms: sides > 1 ? totals[1] : nil,
        samples: weighed.map(&:samples), functions: functions, nodes: nodes, diff: sides > 1
      }
    end

    private

    # What one range weighs: stack id → sampled ms for the heaviest
    # MAX_STACKS stacks, the rest under the pseudo-stack 0 (no frames, so it
    # becomes "(other)"), and how many samples the range holds.
    class Weights < T::Struct
      const :by_stack, T::Hash[Integer, Float]
      const :samples, Integer
    end

    # One scan of profile_samples per range: the window sums run over every
    # group before the LIMIT keeps the heaviest, so the range's total time
    # and sample count come back on each row.
    sig { params(range: Range).returns(Weights) }
    def weigh(range)
      statement = Query::Statement.new
      where = Query::Where.new(source: Query::Sources::PROFILES, context: @context, statement: statement)
      sql = "SELECT stack_id, sum(ms)::float8 AS ms, (sum(sum(ms)) OVER ())::float8 AS total_ms, " \
            "(sum(sum(samples)) OVER ())::bigint AS samples FROM profile_samples " \
            "WHERE #{where.sql(from: range.from, to: range.to, filter: range.filter)} " \
            "GROUP BY 1 ORDER BY 2 DESC LIMIT #{MAX_STACKS + 1}"
      rows = Query::Runner.select(statement.to_sql(sql))
      by_stack = rows.first(MAX_STACKS).to_h { |row| [ row["stack_id"].to_i, row["ms"].to_f ] }
      if rows.size > MAX_STACKS
        by_stack[0] = [ rows.first&.fetch("total_ms").to_f - by_stack.values.sum, 0.0 ].max
      end
      Weights.new(by_stack: by_stack, samples: rows.first&.fetch("samples").to_i)
    end

    sig { params(ids: T::Array[Integer]).returns(T::Hash[Integer, T::Array[Integer]]) }
    def stack_frames(ids)
      ids.reject(&:zero?).each_slice(5_000).each_with_object({}) do |slice, out|
        Telemetry::ProfileStack.where(id: slice, app_id: @context.app_ids).pluck(:id, :frames).each do |id, frames|
          out[id] = frames
        end
      end
    end

    sig { params(root: Node, path: T::Array[Integer], ms: Float, side: Integer).void }
    def add(root, path, ms, side)
      node = root
      node.total_ms[side] = node.total_ms.fetch(side) + ms
      path.each do |function|
        node = (node.children[function] ||= Node.new(function, @ranges.size))
        node.total_ms[side] = node.total_ms.fetch(side) + ms
      end
      node.self_ms[side] = node.self_ms.fetch(side) + ms
    end

    # Every function the kept tree names, as the table nodes index into.
    # Index 0 is the root; "(other)" is appended when anything was pruned.
    sig { params(root: Node).returns([ T::Array[T::Hash[Symbol, T.untyped]], T::Hash[Integer, Integer] ]) }
    def function_table(root)
      ids = T.let(Set.new, T::Set[Integer])
      stack = [ root ]
      while (node = stack.pop)
        ids << node.function if node.function.positive?
        stack.concat(node.children.values)
      end

      rows = ids.each_slice(5_000).flat_map do |slice|
        Telemetry::ProfileFunction.where(id: slice).pluck(:id, :name, :file, :line, :category)
      end
      functions = T.let([ { name: "all", file: "", line: 0, category: "root" } ], T::Array[T::Hash[Symbol, T.untyped]])
      index_of = T.let({ ROOT => 0 }, T::Hash[Integer, Integer])
      rows.each do |id, name, file, line, category|
        index_of[id] = functions.size
        functions << { name: name, file: file, line: line, category: category }
      end
      index_of[OTHER] = functions.size
      functions << { name: "(other)", file: "", line: 0, category: "other" }
      [ functions, index_of ]
    end

    # Preorder, heaviest child first, pruning what is too small to draw into
    # one "(other)" child so a parent's children still add up to it.
    sig do
      params(node: Node, parent: Integer, totals: T::Array[Float], index_of: T::Hash[Integer, Integer],
        out: T::Array[T::Array[T.untyped]]).void
    end
    def flatten(node, parent, totals, index_of, out)
      position = out.size
      out << [ index_of.fetch(node.function, index_of.fetch(OTHER)), parent, *node.self_ms.zip(node.total_ms).flatten ]

      pruned = Array.new(totals.size, 0.0)
      node.children.values.sort_by { |child| -child.total_ms.sum }.each do |child|
        if drawable?(child, totals)
          flatten(child, position, totals, index_of, out)
        else
          child.total_ms.each_with_index { |ms, side| pruned[side] = pruned.fetch(side) + ms }
        end
      end
      return unless pruned.any?(&:positive?)

      out << [ index_of.fetch(OTHER), position, *pruned.zip(pruned).flatten ]
    end

    sig { params(node: Node, totals: T::Array[Float]).returns(T::Boolean) }
    def drawable?(node, totals)
      node.total_ms.each_with_index.any? { |ms, side| totals.fetch(side).positive? && ms / totals.fetch(side) >= MIN_SHARE }
    end
  end
end
