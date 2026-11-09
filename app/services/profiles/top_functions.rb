# typed: strict
# frozen_string_literal: true

module Profiles
  # The functions a profile spent its time in, ranked — the table beside the
  # flamegraph, as an answer rather than a picture. Read off the same merged
  # tree (Flamegraph#build), so the numbers are the console's numbers.
  #
  # `self` is time with the function on top of the stack: where the samples
  # actually landed. `total` is time with it anywhere on the stack, counted
  # once per stack however often it recurses.
  module TopFunctions
    extend T::Sig

    class Order < T::Enum
      enums do
        Self = new("self")
        Total = new("total")
      end
    end

    # The synthetic frames: the root every stack hangs from, and what was
    # pruned. Neither is a function anyone wrote.
    SYNTHETIC = T.let(%w[root other].freeze, T::Array[String])

    sig do
      params(graph: T::Hash[Symbol, T.untyped], limit: Integer, order: Order).returns(T::Array[T::Hash[Symbol, T.untyped]])
    end
    def self.rank(graph, limit:, order: Order::Self)
      functions = T.cast(graph.fetch(:functions), T::Array[T::Hash[Symbol, T.untyped]])
      nodes = T.cast(graph.fetch(:nodes), T::Array[T::Array[T.untyped]])
      whole = graph.fetch(:total_ms).to_f
      self_ms = Array.new(functions.size, 0.0)
      total_ms = Array.new(functions.size, 0.0)

      # Nodes are preorder and name their parent, so the path from the root
      # to the node in hand is a stack: pop back to the parent, then push.
      path = T.let([], T::Array[[ Integer, Integer ]])
      on_path = Array.new(functions.size, 0)
      nodes.each_with_index do |(function, parent, own, total), index|
        while (top = path.last) && top[0] != parent
          on_path[top[1]] = on_path.fetch(top[1]) - 1
          path.pop
        end
        self_ms[function] = self_ms.fetch(function) + own.to_f
        total_ms[function] = total_ms.fetch(function) + total.to_f if on_path.fetch(function).zero?
        on_path[function] = on_path.fetch(function) + 1
        path << [ index, function ]
      end

      rows = functions.each_with_index.filter_map do |function, index|
        next if SYNTHETIC.include?(function[:category].to_s)

        { name: function[:name], file: function[:file], line: function[:line], category: function[:category],
          self_ms: self_ms.fetch(index), self_share: share(self_ms.fetch(index), whole),
          total_ms: total_ms.fetch(index), total_share: share(total_ms.fetch(index), whole) }
      end
      key = order == Order::Total ? :total_ms : :self_ms
      rows.sort_by { |row| -row.fetch(key) }.first(limit)
    end

    sig { params(ms: Float, whole: Float).returns(Float) }
    def self.share(ms, whole) = whole.positive? ? ms / whole : 0.0
    private_class_method :share
  end
end
