# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # A `profile` record: one folded profiling window (docs/ingest-protocol.md).
    # Parsed into a Window that still speaks the record's own local indexes;
    # ProfileStore re-keys its functions and stacks by content.
    module Profile
      extend T::Sig

      MAX_FUNCTIONS = 50_000
      MAX_STACKS = 20_000
      MAX_SAMPLES = 60_000
      MAX_DEPTH = 512
      HZ_RANGE = T.let((1..10_000), T::Range[Integer])
      MAX_WEIGHT = 2_147_483_648

      class Function < T::Struct
        const :name, String
        const :file, String
        const :line, Integer
        const :category, String
      end

      class Sample < T::Struct
        const :stack, Integer
        const :transaction, T.nilable(String)
        const :state, String
        const :weight, Integer
      end

      class Window < T::Struct
        const :ts, Time
        const :hz, Integer
        const :request_id, T.nilable(String)
        const :functions, T::Array[Function]
        const :stacks, T::Array[T::Array[Integer]]
        const :samples, T::Array[Sample]
      end

      sig { params(record: Record, context: Context).returns(T.nilable(Window)) }
      def self.build(record, context)
        hz = record["hz"]
        funcs = record["funcs"]
        stacks = record["stacks"]
        samples = record["samples"]
        return nil unless hz.is_a?(Integer) && HZ_RANGE.cover?(hz)
        return nil unless funcs.is_a?(Array) && stacks.is_a?(Array) && samples.is_a?(Array)
        return nil if funcs.size > MAX_FUNCTIONS || stacks.size > MAX_STACKS || samples.size > MAX_SAMPLES

        functions = T.let([], T::Array[Function])
        funcs.each do |entry|
          parsed = function(entry)
          return nil if parsed.nil?

          functions << parsed
        end

        # A stack is only as good as every index in it.
        valid_stacks = stacks.all? do |frames|
          frames.is_a?(Array) && frames.size.between?(1, MAX_DEPTH) &&
            frames.all? { |index| index.is_a?(Integer) && index >= 0 && index < functions.size }
        end
        return nil unless valid_stacks

        kept = samples.filter_map { |entry| sample(entry, stacks.size) }
        return nil if kept.empty?

        Window.new(ts: context.time(record), hz: hz, request_id: Coerce.str(record["request"], max: 64),
          functions: functions, stacks: stacks, samples: kept)
      end

      sig { params(entry: T.untyped).returns(T.nilable(Function)) }
      def self.function(entry)
        return nil unless entry.is_a?(Array)

        name = Coerce.str(entry[0], max: 300)
        return nil if name.nil?

        category = entry[3]
        Function.new(name: name, file: Coerce.str(entry[1], max: 400) || "", line: Coerce.int(entry[2]) || 0,
          category: Coerce.one_of(category, Telemetry::ProfileFunction::CATEGORIES, "app"))
      end
      private_class_method :function

      sig { params(entry: T.untyped, stacks: Integer).returns(T.nilable(Sample)) }
      def self.sample(entry, stacks)
        return nil unless entry.is_a?(Array)

        stack, transaction, state, weight = entry
        return nil unless stack.is_a?(Integer) && stack >= 0 && stack < stacks
        return nil unless weight.is_a?(Integer) && weight.positive? && weight < MAX_WEIGHT

        Sample.new(stack: stack, transaction: Coerce.str(transaction, max: 200),
          state: Coerce.one_of(state, Telemetry::ProfileSample::STATES, "running"), weight: weight)
      end
      private_class_method :sample
    end
  end
end
