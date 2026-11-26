# frozen_string_literal: true

module SchemaShard
  # Prepended onto ActiveRecord::Base.singleton_class to route connection,
  # lease_connection, retrieve_connection, and connection_pool calls to the active
  # shard connection ONLY when a shard is active AND the model is routable.
  module ConnectionPatch
    def connection
      conn = SchemaShard.active_connection
      if conn && SchemaShard.routable_model?(self)
        raise_if_tainted!
        return conn
      end

      super
    end

    def lease_connection
      conn = SchemaShard.active_connection
      if conn && SchemaShard.routable_model?(self)
        raise_if_tainted!
        return conn
      end

      super
    end

    def retrieve_connection
      conn = SchemaShard.active_connection
      if conn && SchemaShard.routable_model?(self)
        raise_if_tainted!
        return conn
      end

      super
    end

    def connection_pool
      pool = SchemaShard.active_pool
      if pool && SchemaShard.routable_model?(self)
        raise_if_tainted!
        return pool
      end

      super
    end

    private

    def raise_if_tainted!
      return unless SchemaShard::ExecutionContext.active_pool_tainted?

      raise SchemaShard::TaintedConnectionError, 'Active shard connection was discarded due to a prior taint'
    end
  end
end
