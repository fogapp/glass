# typed: strict
# frozen_string_literal: true

module Ingest
  # A profiling window → rows. The window names its functions and stacks by
  # position; here they are re-keyed by content into the two dictionaries
  # (so a stack seen in a thousand windows is stored once), and the samples
  # become rows that name a stack by id.
  #
  # Both dictionaries are remembered per process, like metric series: a
  # steady app sends the same few thousand stacks every minute, and only a
  # stack never seen before costs a query. Both live in one DictionaryCache,
  # so they are forgotten together — a stack remembered never outlives the
  # functions it was built from in memory — and after
  # Telemetry::Dictionaries::CACHE_TTL, because stacks and functions no
  # sample names any more are pruned (that module says why an hour is
  # enough to keep a pruned id from being written again).
  class ProfileStore
    extend T::Sig

    # Functions and stacks together (up to 400,000 of each before).
    CACHE_LIMIT = 800_000

    Key = T.type_alias { [ String, Integer, Integer ] } # table, app, content hash

    @cache = T.let(DictionaryCache[Key].new(limit: CACHE_LIMIT), DictionaryCache[Key])

    class << self
      extend T::Sig

      sig { void }
      def reset!
        @cache.reset!
      end

      # The window's samples as profile_samples rows.
      sig do
        params(app: App, header: Batch::Header, window: Records::Profile::Window)
          .returns(T::Array[T::Hash[Symbol, T.untyped]])
      end
      def rows(app, header, window)
        app_id = app.telemetry_id
        function_ids = resolve_functions(app_id, window.functions)
        stack_ids = resolve_stacks(app_id, window.stacks.map { |frames| frames.map { |index| T.must(function_ids[index]) } })

        # One row per (stack, transaction, state): an agent may send the
        # same combination twice.
        folded = Hash.new(0)
        window.samples.each { |sample| folded[[ T.must(stack_ids[sample.stack]), sample.transaction, sample.state ]] += sample.weight }
        per_sample_ms = 1000.0 / window.hz
        provenance = header.provenance(ts: window.ts, app_id: app_id)
        folded.map do |(stack_id, transaction, state), weight|
          { **provenance, txn: transaction, state: state, stack_id: stack_id, samples: weight, ms: weight * per_sample_ms,
            request_id: window.request_id }
        end
      end

      private

      sig { params(app_id: Integer, functions: T::Array[Records::Profile::Function]).returns(T::Array[Integer]) }
      def resolve_functions(app_id, functions)
        hashes = functions.map { |function| Telemetry::ProfileFunction.identity(function.name, function.file) }
        rows = functions.zip(hashes).map do |function, hash|
          { app_id: app_id, digest: hash, name: function.name, file: function.file, line: function.line, category: function.category }
        end
        resolve(Telemetry::ProfileFunction, app_id, hashes, rows)
      end

      sig { params(app_id: Integer, stacks: T::Array[T::Array[Integer]]).returns(T::Array[Integer]) }
      def resolve_stacks(app_id, stacks)
        hashes = stacks.map { |frames| Telemetry::ProfileStack.identity(frames) }
        rows = stacks.zip(hashes).map { |frames, hash| { app_id: app_id, digest: hash, frames: frames } }
        resolve(Telemetry::ProfileStack, app_id, hashes, rows)
      end

      # Ids for the hashes, in order: from memory, then the table, then by
      # inserting what is new (ON CONFLICT covers a concurrent window).
      sig do
        params(model: T.class_of(TelemetryRecord), app_id: Integer, hashes: T::Array[Integer],
          rows: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Array[Integer])
      end
      def resolve(model, app_id, hashes, rows)
        table = model.table_name
        known = @cache.fetch_many(hashes.uniq.map { |hash| [ table, app_id, hash ] }).transform_keys(&:last)
        missing = hashes.uniq - known.keys

        unless missing.empty?
          found = lookup(model, app_id, missing)
          absent = missing - found.keys
          unless absent.empty?
            wanted = absent.to_set
            new_rows = rows.select { |row| wanted.delete?(row[:digest]) }
            new_rows.each_slice(2_000) { |slice| model.insert_all(slice, unique_by: %i[app_id digest]) } # rubocop:disable Rails/SkipsModelValidations
            found.merge!(lookup(model, app_id, absent))
          end
          known.merge!(found)
          @cache.remember(found.transform_keys { |hash| [ table, app_id, hash ] })
        end

        hashes.map { |hash| known.fetch(hash) }
      end

      sig { params(model: T.class_of(TelemetryRecord), app_id: Integer, hashes: T::Array[Integer]).returns(T::Hash[Integer, Integer]) }
      def lookup(model, app_id, hashes)
        hashes.each_slice(5_000).each_with_object({}) do |slice, out|
          model.where(app_id: app_id, digest: slice).pluck(:digest, :id).each { |hash, id| out[hash] = id }
        end
      end
    end
  end
end
