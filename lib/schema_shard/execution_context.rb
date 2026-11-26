# frozen_string_literal: true

module SchemaShard
  module ExecutionContext
    CONFIG_KEY     = :schema_shard_config
    LABEL_KEY      = :schema_shard_label
    TENANT_KEY     = :schema_shard_tenant
    CONNECTION_KEY = :schema_shard_connection
    POOL_KEY       = :schema_shard_pool
    READ_ONLY_KEY  = :schema_shard_read_only

    module_function

    def state
      if defined?(ActiveSupport::IsolatedExecutionState)
        ActiveSupport::IsolatedExecutionState
      else
        Thread.current
      end
    end

    def current_config
      state[CONFIG_KEY]
    end

    def current_shard_label
      state[LABEL_KEY]
    end

    def current_tenant
      state[TENANT_KEY]
    end

    def active_connection
      state[CONNECTION_KEY]
    end

    def active_pool
      state[POOL_KEY]
    end

    def read_only?
      state[READ_ONLY_KEY]
    end

    def with_context(shard_key:, config:, tenant:, read_only:)
      st = state
      prev_config    = st[CONFIG_KEY]
      prev_label     = st[LABEL_KEY]
      prev_tenant    = st[TENANT_KEY]
      prev_read_only = st[READ_ONLY_KEY]

      st[CONFIG_KEY]     = config
      st[LABEL_KEY]      = shard_key
      st[TENANT_KEY]     = tenant
      st[READ_ONLY_KEY]  = read_only

      yield
    ensure
      st[CONFIG_KEY]     = prev_config
      st[LABEL_KEY]      = prev_label
      st[TENANT_KEY]     = prev_tenant
      st[READ_ONLY_KEY]  = prev_read_only
    end

    def with_connection(conn, pool)
      st = state
      prev_conn = st[CONNECTION_KEY]
      prev_pool = st[POOL_KEY]

      st[CONNECTION_KEY] = conn
      st[POOL_KEY]       = pool
      yield
    ensure
      st[CONNECTION_KEY] = prev_conn
      st[POOL_KEY]       = prev_pool
    end

    def clear!(logger: nil)
      st = state
      logger&.warn '[SchemaShard] clear_thread_locals! called while a shard connection was active' if st[CONNECTION_KEY]

      st[CONFIG_KEY]     = nil
      st[LABEL_KEY]      = nil
      st[TENANT_KEY]     = nil
      st[CONNECTION_KEY] = nil
      st[POOL_KEY]       = nil
      st[READ_ONLY_KEY]  = nil
    end
  end
end
