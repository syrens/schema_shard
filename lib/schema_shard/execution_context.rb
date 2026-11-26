# frozen_string_literal: true

module SchemaShard
  module ExecutionContext
    CONFIG_KEY      = :schema_shard_config
    LABEL_KEY       = :schema_shard_label
    TENANT_KEY      = :schema_shard_tenant
    CONNECTION_KEY  = :schema_shard_connection
    POOL_KEY        = :schema_shard_pool
    READ_ONLY_KEY   = :schema_shard_read_only
    POOL_FRAMES_KEY = :schema_shard_pool_frames
    DEPTH_KEY       = :schema_shard_depth

    module_function

    def state
      if defined?(ActiveSupport::IsolatedExecutionState)
        ActiveSupport::IsolatedExecutionState
      else
        Thread.current
      end
    end

    def current_config      = state[CONFIG_KEY]
    def current_shard_label = state[LABEL_KEY]
    def current_tenant      = state[TENANT_KEY]
    def active_connection   = state[CONNECTION_KEY]
    def active_pool         = state[POOL_KEY]
    def read_only?          = state[READ_ONLY_KEY]

    def in_active_block?
      state[DEPTH_KEY].to_i.positive?
    end

    def pool_active_on_thread?(pool)
      frames = state[POOL_FRAMES_KEY]
      return false unless frames

      stack = frames[pool]
      !stack.nil? && !stack.empty?
    end

    def enclosing_pool_frame(pool)
      frames = state[POOL_FRAMES_KEY]
      return nil unless frames

      stack = frames[pool]
      stack&.last
    end

    def push_pool_frame(pool, tenant:, tenant_switched:)
      st = state
      frames = (st[POOL_FRAMES_KEY] ||= {}.compare_by_identity)
      stack  = (frames[pool] ||= [])
      frame  = { tenant: tenant, tenant_switched: tenant_switched, dirty: false, tainted: false }
      stack.push(frame)
      frame
    end

    def pop_pool_frame(pool)
      frames = state[POOL_FRAMES_KEY]
      return nil unless frames

      stack = frames[pool]
      return nil unless stack

      frame = stack.pop
      frames.delete(pool) if stack.empty?
      frame
    end

    def mark_pool_frames_dirty(pool)
      frames = state[POOL_FRAMES_KEY]
      return unless frames

      frames[pool]&.each { |f| f[:dirty] = true }
    end

    def mark_pool_frames_tainted(pool)
      frames = state[POOL_FRAMES_KEY]
      return unless frames

      frames[pool]&.each { |f| f[:tainted] = true }
    end

    def active_pool_tainted?
      pool = state[POOL_KEY]
      return false unless pool

      enclosing_pool_frame(pool)&.dig(:tainted) == true
    end

    def with_context(shard_key:, config:, tenant:, read_only:)
      st = state
      prev_config    = st[CONFIG_KEY]
      prev_label     = st[LABEL_KEY]
      prev_tenant    = st[TENANT_KEY]
      prev_read_only = st[READ_ONLY_KEY]
      prev_depth     = st[DEPTH_KEY].to_i

      st[CONFIG_KEY]    = config
      st[LABEL_KEY]     = shard_key
      st[TENANT_KEY]    = tenant
      st[READ_ONLY_KEY] = read_only
      st[DEPTH_KEY]     = prev_depth + 1

      yield
    ensure
      st[CONFIG_KEY]    = prev_config
      st[LABEL_KEY]     = prev_label
      st[TENANT_KEY]    = prev_tenant
      st[READ_ONLY_KEY] = prev_read_only
      st[DEPTH_KEY]     = prev_depth
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

      st[CONFIG_KEY]      = nil
      st[LABEL_KEY]       = nil
      st[TENANT_KEY]      = nil
      st[CONNECTION_KEY]  = nil
      st[POOL_KEY]        = nil
      st[READ_ONLY_KEY]   = nil
      st[POOL_FRAMES_KEY] = nil
      st[DEPTH_KEY]       = 0
    end
  end
end
