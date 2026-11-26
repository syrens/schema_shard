# frozen_string_literal: true

require 'concurrent'

module SchemaShard
  # Atomic refcount + eviction state bound to one ActiveRecord::ConnectionAdapters::ConnectionPool.
  # Uses Dekker-style store-load ordering so concurrent eviction never races with active checkouts.
  class PoolEntry
    attr_reader :pool, :pool_key, :shard_key, :refcount, :evicted

    def initialize(pool:, pool_key:, shard_key:, accessed_at:)
      @pool          = pool
      @pool_key      = pool_key
      @shard_key     = shard_key
      @refcount      = Concurrent::AtomicFixnum.new(0)
      @evicted       = Concurrent::AtomicBoolean.new(false)
      @last_accessed = Concurrent::AtomicReference.new(accessed_at)
    end

    def touch(now)
      @last_accessed.set(now)
    end

    def last_accessed
      @last_accessed.get
    end

    # Increment refcount BEFORE checking evicted; pairs with eviction setting evicted BEFORE reading refcount.
    def try_acquire?(now)
      @refcount.increment
      if @evicted.true?
        @refcount.decrement
        return false
      end

      touch(now)
      true
    end

    def release
      @refcount.decrement
    end
  end
end
