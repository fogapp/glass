# typed: strict
# frozen_string_literal: true

# The loop every bounded DELETE here shares: run the statement up to
# `max_batches` times, each removing at most `batch` rows, and stop as soon
# as one comes back short — a short batch means there is nothing left. The
# cap is a backstop, not a policy: what is left over waits for the next run
# rather than holding a connection until it drains.
#
# The block is handed the limit and returns how many rows the batch
# covered; the statement itself stays with its caller.
module BatchedDelete
  extend T::Sig

  sig { params(batch: Integer, max_batches: Integer, blk: T.proc.params(limit: Integer).returns(Integer)).returns(Integer) }
  def self.run(batch:, max_batches:, &blk)
    total = T.let(0, Integer)
    max_batches.times do
      count = yield batch
      total += count
      break if count < batch
    end
    total
  end
end
