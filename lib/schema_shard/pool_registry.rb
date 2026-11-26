# frozen_string_literal: true

require 'concurrent'
require 'digest'
require 'json'

module SchemaShard
  class PoolRegistry
    POOL_IDENTITY_KEYS = %w[
      adapter
      host
      port
      socket
      database
      username
      url
      sslmode
      ssl_mode
      sslrootcert
      sslcert
      sslkey
      variables
      pragmas
      schema_search_path
      prepared_statements
      advisory_locks
      pool
      checkout_timeout
      timeout
      reaping_frequency
      encoding
    ].freeze

    def initialize(configuration:, metrics:)
      @configuration    = configuration
      @metrics          = metrics
      @mutex            = Mutex.new
      @connection_pools = Concurrent::Map.new
      @pool_keys_cache  = Concurrent::Map.new
    end

    def acquire(config, shard_key, db_adapter:, read_only: true, tenant: nil)
      resolved_config = db_adapter.resolve_shard_config(config, tenant: tenant)
      per_tenant      = db_adapter.per_tenant_pool?(config)
      pool_key        = resolve_pool_key(resolved_config, shard_key,
                                         read_only: read_only, per_tenant_pool: per_tenant)

      loop do
        now = monotonic_now

        # Always try lock-free fast path for an existing live pool before locking.
        existing = @connection_pools[pool_key]
        if existing
          return existing if existing.try_acquire?(now)

          next
        end

        acquired = acquire_under_lock(resolved_config, shard_key, pool_key, db_adapter: db_adapter,
                                                                            read_only: read_only, now: now)
        return acquired if acquired
      end
    end

    def clear_key_cache!
      @pool_keys_cache.clear
    end

    def pool_count
      @connection_pools.size
    end

    def pool_usage_info
      @mutex.synchronize do
        {
          current_pools: @connection_pools.size,
          max_pools: @configuration.max_pools,
          cleanup_threshold: @configuration.cleanup_threshold,
          usage_percentage: percent_used,
          oldest_pool_age: oldest_pool_age_seconds,
          pool_keys: @connection_pools.keys
        }
      end
    end

    def pool_status_snapshot
      count = @connection_pools.size
      {
        active_count: count,
        max_allowed: @configuration.max_pools,
        cleanup_threshold: @configuration.cleanup_threshold,
        usage_percentage: (count.to_f / @configuration.max_pools * 100).round(2)
      }
    end

    def pool_statistics
      snapshot = @mutex.synchronize do
        @connection_pools.each_pair.with_object({}) { |(k, entry), acc| acc[k] = entry.pool }
      end

      snapshot.transform_values do |pool|
        stat = safe_pool_stat(pool, fail_closed: false)
        {
          size: stat[:size],
          checked_out: stat[:busy],
          available: [stat[:size] - stat[:busy], 0].max,
          pool_config: extract_pool_config_summary(pool)
        }
      end
    end

    def total_active_connections
      @connection_pools.values.sum { |entry| safe_pool_stat(entry.pool, fail_closed: false)[:busy] }
    end

    def cleanup_connection_pools!
      pools_to_disconnect = []

      @mutex.synchronize do
        @connection_pools.each_value do |entry|
          if entry.refcount.value.positive?
            logger&.warn "[SchemaShard] Force-cleaning pool '#{entry.pool_key}' " \
                         "with #{entry.refcount.value} active thread reference(s)"
          end
          entry.evicted.make_true
          pools_to_disconnect << entry.pool
        end
        @connection_pools.clear
        @pool_keys_cache.clear
      end

      pools_to_disconnect.each { |pool| safe_disconnect(pool) }

      if pools_to_disconnect.any?
        @metrics.increment(:pools_cleanup_total, 1)
        @metrics.increment(:pools_evicted_total, pools_to_disconnect.size)
      end

      logger&.info '[SchemaShard] All connection pools cleaned up'
    end

    def cleanup_unused_pools!
      evicted_pools = []

      @mutex.synchronize do
        @connection_pools.keys.each do |key| # rubocop:disable Style/HashEachMethods
          pool = try_evict_pool_without_lock(key)
          evicted_pools << pool if pool
        end
      end

      evicted_pools.each { |pool| safe_disconnect(pool) }
      removed = evicted_pools.size

      if removed.positive?
        @metrics.increment(:pools_cleanup_total, 1)
        @metrics.increment(:pools_evicted_total, removed)
        logger&.info "[SchemaShard] Removed #{removed} unused pools"
      end

      removed
    end

    def discard_pools_after_fork!
      pools_to_discard = []

      @mutex.synchronize do
        @connection_pools.each_value do |entry|
          entry.evicted.make_true
          pools_to_discard << entry.pool
        end
        @connection_pools.clear
        @pool_keys_cache.clear
      end

      pools_to_discard.each { |pool| safe_discard_pool(pool) }
      nil
    end

    def build_pool_key(config, shard_key, read_only: true)
      str_config = stringify_keys(config)
      identity   = POOL_IDENTITY_KEYS.each_with_object({}) do |k, acc|
        acc[k] = str_config[k] if str_config.key?(k)
      end
      identity['password_digest'] = Digest::SHA256.hexdigest(str_config['password'].to_s) if str_config.key?('password')
      identity['read_only'] = read_only

      digest = Digest::SHA256.hexdigest(JSON.generate(identity))[0, 16]
      "#{shard_key}_#{digest}"
    end

    def build_connection_pool(config, pool_key, db_adapter:, read_only: true)
      merged = merge_pool_options(config, db_adapter: db_adapter, read_only: read_only)

      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        @configuration.effective_env,
        pool_key.to_s,
        symbolize_keys(merged)
      )

      pool_config = ActiveRecord::ConnectionAdapters::PoolConfig.new(
        ActiveRecord::Base,
        db_config,
        read_only ? :reading : :writing,
        pool_key.to_sym
      )

      ActiveRecord::ConnectionAdapters::ConnectionPool.new(pool_config)
    end

    private

    def merge_pool_options(config, db_adapter:, read_only:)
      str_config = resolve_url_options(stringify_keys(config))
      merged     = db_adapter.default_pool_options(@configuration).merge(str_config)
      merged['pool']              = [merged['pool'].to_i, 1].max
      timeout_val                 = merged['checkout_timeout'].to_f
      merged['checkout_timeout']  = timeout_val.positive? ? timeout_val : @configuration.checkout_timeout.to_f
      merged['reaping_frequency'] = (merged['reaping_frequency'] || @configuration.reaping_frequency).to_f
      read_only ? db_adapter.apply_read_only_config(merged) : merged
    end

    def resolve_url_options(str_config)
      url = str_config['url']
      return str_config if url.nil? || url.to_s.strip.empty?

      require 'active_record' unless defined?(ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver)
      resolved = ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver.new(url.to_s)
                                                                            .to_hash.transform_keys(&:to_s)
      resolved.merge(str_config.except('url').compact)
    end

    def acquire_under_lock(resolved_config, shard_key, pool_key, db_adapter:, read_only:, now:)
      created       = false
      evicted_pools = []
      lru_removed   = 0
      acquired      = nil

      begin
        @mutex.synchronize do
          entry = @connection_pools[pool_key]
          if entry&.try_acquire?(now)
            acquired = entry
          else
            if @connection_pools.size >= @configuration.cleanup_threshold
              lru_evicted = run_lru_cleanup_without_lock!(exclude_key: pool_key)
              lru_removed = lru_evicted.size
              evicted_pools.concat(lru_evicted)
            end

            evicted_pools.concat(enforce_pool_limit_without_lock!(pool_key))

            new_pool  = build_connection_pool(resolved_config, pool_key, db_adapter: db_adapter, read_only: read_only)
            new_entry = PoolEntry.new(pool: new_pool, pool_key: pool_key, shard_key: shard_key, accessed_at: now)
            new_entry.try_acquire?(now)
            @connection_pools[pool_key] = new_entry
            acquired = new_entry
            created  = true
          end
        end
      ensure
        evicted_pools.each { |evicted_pool| safe_disconnect(evicted_pool) }
      end

      log_pool_created(pool_key) if created
      record_acquire_metrics(shard_key, created: created, evicted_count: evicted_pools.size, lru_removed: lru_removed)
      acquired
    end

    def log_pool_created(pool_key)
      logger&.info "[SchemaShard] Created pool '#{pool_key}' (#{@connection_pools.size}/#{@configuration.max_pools})"
    rescue StandardError
      nil
    end

    def record_acquire_metrics(shard_key, created:, evicted_count:, lru_removed:)
      if created
        @metrics.increment(:pools_created_total)
        @metrics.increment_shard(shard_key, :pools_created_total)
      end
      return unless evicted_count.positive?

      @metrics.increment(:pools_evicted_total, evicted_count)
      @metrics.increment(:pools_cleanup_total, 1) if lru_removed.positive?
    end

    # Skip @pool_keys_cache for per-tenant pools to avoid unbounded RAM growth.
    def resolve_pool_key(config, shard_key, read_only:, per_tenant_pool:)
      return build_pool_key(config, shard_key, read_only: read_only) if per_tenant_pool

      cache_id = "#{@configuration.effective_env}:#{shard_key}:#{read_only ? 'ro' : 'rw'}"
      @pool_keys_cache.compute_if_absent(cache_id) do
        build_pool_key(config, shard_key, read_only: read_only)
      end
    end

    def enforce_pool_limit_without_lock!(pool_key)
      return [] if @connection_pools.size < @configuration.max_pools

      evicted_list = []
      sorted_candidates = @connection_pools
                          .each_pair
                          .reject { |k, _| k == pool_key }
                          .sort_by { |_, entry| entry.last_accessed }
                          .map(&:first)

      sorted_candidates.each do |candidate_key|
        break if @connection_pools.size < @configuration.max_pools

        evicted = try_evict_pool_without_lock(candidate_key)
        next unless evicted

        logger&.warn "[SchemaShard] Pool limit reached; evicting '#{candidate_key}'"
        evicted_list << evicted
      end

      return evicted_list if @connection_pools.size < @configuration.max_pools

      raise PoolLimitExceededError,
            "Connection pool limit (#{@configuration.max_pools}) reached and no idle evictable pool found"
    end

    def run_lru_cleanup_without_lock!(exclude_key: nil)
      target      = [@configuration.cleanup_threshold - 2, 0].max
      sorted_keys = @connection_pools
                    .each_pair
                    .reject { |k, _| k == exclude_key }
                    .sort_by { |_, entry| entry.last_accessed }
                    .map(&:first)
      evicted     = []

      sorted_keys.each do |key|
        break if @connection_pools.size <= target

        pool = try_evict_pool_without_lock(key)
        evicted << pool if pool
      end

      logger&.info "[SchemaShard] LRU cleanup removed #{evicted.size} pools" if evicted.any?
      evicted
    end

    def try_evict_pool_without_lock(pool_key)
      entry = @connection_pools.delete(pool_key)
      return nil unless entry

      entry.evicted.make_true
      in_use = entry.refcount.value.positive? || safe_pool_stat(entry.pool, fail_closed: true)[:busy].positive?

      if in_use
        entry.evicted.make_false
        @connection_pools[pool_key] = entry
        return nil
      end

      entry.pool
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def safe_pool_stat(pool, fail_closed: true)
      pool.stat
    rescue StandardError
      { size: 0, busy: fail_closed ? 1 : 0, dead: 0, idle: 0, waiting: 0, checkout_timeout: 0 }
    end

    def extract_pool_config_summary(pool)
      cfg = pool.respond_to?(:db_config) ? pool.db_config.configuration_hash : {}
      {
        pool_size: pool.respond_to?(:size) ? pool.size : cfg[:pool],
        checkout_timeout: pool.respond_to?(:checkout_timeout) ? pool.checkout_timeout : cfg[:checkout_timeout]
      }
    rescue StandardError
      { pool_size: nil, checkout_timeout: nil }
    end

    def safe_disconnect(pool)
      pool.disconnect!
      true
    rescue StandardError => e
      logger&.warn "[SchemaShard] Error disconnecting pool: #{e.message}"
      false
    end

    # Never call disconnect! in a forked child — it would transmit Terminate/COM_QUIT
    # packets over sockets inherited from the parent process.
    def safe_discard_pool(pool)
      if pool.respond_to?(:discard!)
        pool.discard!
      elsif pool.respond_to?(:discard_pool!)
        pool.discard_pool!
      else
        logger&.error '[SchemaShard] Pool does not support #discard!; dropping reference without disconnecting'
        return false
      end
      true
    rescue StandardError => e
      logger&.warn "[SchemaShard] Error discarding pool after fork: #{e.message}"
      false
    end

    def percent_used
      (@connection_pools.size.to_f / @configuration.max_pools * 100).round(2)
    end

    def oldest_pool_age_seconds
      min_time = @connection_pools.values.map(&:last_accessed).min
      return 0 unless min_time

      [(monotonic_now - min_time).to_i, 0].max
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def symbolize_keys(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end

    def logger
      @configuration.effective_logger
    end
  end
end
