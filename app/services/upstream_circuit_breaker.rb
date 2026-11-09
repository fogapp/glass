# typed: strict
# frozen_string_literal: true

# Shared circuit breaker over Rails.cache (Solid Cache in production, so every
# Puma thread and every Solid Queue worker sees the same state).
#
# Why this exists: Glass reaches fogd every minute (Fog::Sync) and fogd and
# ntfy whenever a monitor fires (FogEvents, push notifications). An
# unreachable fogd or ntfy must cost one connect timeout, not one per job: a
# monitor sweep that notifies several incidents, or a sync that asks fog
# about each app, would otherwise hold a worker thread on the same dead host
# again and again.
#
# It counts before it opens. A single reset connection is ordinary and says
# nothing about whether a host is up; opening on the first one would let one
# dropped packet silence every notification for the cooldown, including the
# ones that would have gone through. Three in a row is a pattern. The count lives in the cache alongside the breaker itself,
# so it decays on its own if the failures stop coming — a host that fails once
# an hour never accumulates its way to open.
module UpstreamCircuitBreaker
  extend T::Sig

  COOLDOWN = T.let(60.seconds, ActiveSupport::Duration)
  # Consecutive failures before the breaker opens.
  THRESHOLD = 3
  # How long a failure counts toward the threshold. Deliberately longer than
  # the cooldown: the question the counter answers is "is this host having a
  # bad few minutes", and a window shorter than the retry interval could never
  # observe one.
  FAILURE_WINDOW = T.let(5.minutes, ActiveSupport::Duration)

  sig { params(key: String).returns(T::Boolean) }
  def self.open?(key)
    Rails.cache.exist?(cache_key(key))
  end

  # Records a failure and opens only once they add up. Returns whether the
  # breaker is now open, so a caller can say something different about the
  # request that tripped it.
  sig { params(key: String).returns(T::Boolean) }
  def self.trip!(key)
    failures = Rails.cache.increment(failure_key(key), 1, expires_in: FAILURE_WINDOW).to_i
    # Solid Cache's increment starts a missing counter at the amount rather
    # than raising, but a store that returns nil for a fresh key would make
    # this read zero forever — treat anything falsy as the first failure.
    failures = 1 if failures.zero?
    return false if failures < THRESHOLD

    Rails.cache.write(cache_key(key), true, expires_in: COOLDOWN)
    true
  end

  # Success clears both: the breaker and the tally that would have opened it.
  # Without the second half, three failures spread across an afternoon of
  # otherwise healthy fetches would eventually open a breaker on a host that
  # is plainly working.
  #
  # Read before delete: on the healthy path — the overwhelming majority of
  # requests, Solid Cache means every one of these is a database round trip —
  # neither key exists, and two blind DELETEs were two write statements per
  # successful fetch. One batched read now answers "anything to clear?", and
  # the deletes only run while a host is actually misbehaving.
  sig { params(key: String).void }
  def self.reset!(key)
    keys = [ cache_key(key), failure_key(key) ]
    return if Rails.cache.read_multi(*keys).empty?

    keys.each { |stale| Rails.cache.delete(stale) }
  end

  sig { params(key: String).returns(String) }
  def self.cache_key(key) = "upstream_circuit_open:#{key}"

  sig { params(key: String).returns(String) }
  def self.failure_key(key) = "upstream_circuit_failures:#{key}"

  private_class_method :cache_key, :failure_key
end
