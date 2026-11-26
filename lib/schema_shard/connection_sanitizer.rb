# frozen_string_literal: true

module SchemaShard
  class ConnectionSanitizer
    def initialize(configuration:, metrics:)
      @configuration = configuration
      @metrics       = metrics
    end

    def clear_query_cache!(pool, conn)
      conn.clear_query_cache if conn.respond_to?(:clear_query_cache)
      pool.clear_query_cache if pool.respond_to?(:clear_query_cache)
    end

    def verify_nested_clean!(pool, conn, shard_key:, db_adapter:, tenant_adapter:, shard_config:, **opts)
      outer_tenant    = opts[:outer_tenant]
      tenant_switched = opts.fetch(:tenant_switched, false)
      verify_live     = opts.fetch(:verify_live, false)

      if db_adapter.non_idle_transaction?(conn)
        discard_tainted(pool, conn, shard_key, 'nested non-idle transaction')
        ExecutionContext.mark_pool_frames_tainted(pool)
        raise TaintedConnectionError, "Connection on '#{shard_key}' left in non-idle transaction after nested switch"
      end

      if outer_tenant
        db_adapter.verify_and_restore_namespace!(
          conn,
          expected_tenant: outer_tenant,
          persistent_schemas: tenant_adapter.persistent_schemas,
          live: verify_live
        )
      elsif tenant_switched && db_adapter.supports_namespaces?
        db_adapter.verify_and_reset_default_namespace!(
          conn,
          default_namespace: tenant_adapter.default_namespace(shard_config, db_adapter: db_adapter),
          persistent_schemas: tenant_adapter.persistent_schemas,
          live: verify_live
        )
      end
    rescue TaintedConnectionError
      raise
    rescue StandardError => e
      discard_tainted(pool, conn, shard_key, "failed to restore outer tenant namespace: #{e.message}")
      ExecutionContext.mark_pool_frames_tainted(pool)
      raise TaintedConnectionError, "Failed to restore outer tenant namespace on '#{shard_key}': #{e.message}"
    end

    def sanitize_before_checkin(pool, conn, shard_key:, db_adapter:, tenant_adapter:, shard_config:, **opts)
      tenant_switched = opts.fetch(:tenant_switched, false)
      verify_live     = opts.fetch(:verify_live, false)
      clear_query_cache!(pool, conn)

      if db_adapter.non_idle_transaction?(conn)
        discard_tainted(pool, conn, shard_key, 'non-idle or unverifiable transaction state')
        return
      end

      if tenant_switched && db_adapter.supports_namespaces?
        db_adapter.verify_and_reset_default_namespace!(
          conn,
          default_namespace: tenant_adapter.default_namespace(shard_config, db_adapter: db_adapter),
          persistent_schemas: tenant_adapter.persistent_schemas,
          live: verify_live
        )
      end

      conn.clear_cache! if conn.respond_to?(:clear_cache!)
    rescue StandardError => e
      discard_tainted(pool, conn, shard_key, "sanitization error: #{e.message}")
    end

    # Removes the connection from the pool FIRST so a subsequent discard!/disconnect!
    # error can never leave a tainted connection inside the pool's available queue.
    def discard_tainted(pool, conn, shard_key, reason)
      logger&.warn "[SchemaShard] Discarding tainted connection on '#{shard_key}' (#{reason})"
      @metrics.increment(:connection_discards_total)
      @metrics.increment_shard(shard_key, :connection_discards_total)

      errors = []
      run_discard_step(errors) { pool.remove(conn) if pool.respond_to?(:remove) }
      run_discard_step(errors) { conn.discard! if conn.respond_to?(:discard!) }
      run_discard_step(errors) { conn.disconnect! if conn.respond_to?(:disconnect!) }

      return if errors.empty?

      msg = errors.map(&:message).join('; ')
      logger&.error "[SchemaShard] Failed to discard tainted connection on '#{shard_key}': #{msg}"
      raise TaintedConnectionError, "Failed to discard tainted connection on '#{shard_key}': #{msg}"
    end

    private

    def run_discard_step(errors)
      yield
    rescue StandardError => e
      errors << e
    end

    def logger
      @configuration.effective_logger
    end
  end
end
