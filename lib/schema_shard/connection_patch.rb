# frozen_string_literal: true

module SchemaShard
  # Prepended onto ActiveRecord::Base.singleton_class to route connection,
  # lease_connection, retrieve_connection, and connection_pool calls to the active
  # shard connection ONLY when a shard is active AND the model is routable.
  module ConnectionPatch
    def connection
      conn = SchemaShard.active_connection
      return conn if conn && SchemaShard.routable_model?(self)

      super
    end

    def lease_connection
      conn = SchemaShard.active_connection
      return conn if conn && SchemaShard.routable_model?(self)

      super
    end

    def retrieve_connection
      conn = SchemaShard.active_connection
      return conn if conn && SchemaShard.routable_model?(self)

      super
    end

    def connection_pool
      pool = SchemaShard.active_pool
      return pool if pool && SchemaShard.routable_model?(self)

      super
    end
  end
end
