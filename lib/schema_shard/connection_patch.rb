# frozen_string_literal: true

module SchemaShard
  # Prepended onto ActiveRecord::Base.singleton_class to route connection and
  # connection_pool calls to the active shard connection ONLY for routable models.
  module ConnectionPatch
    def connection
      if SchemaShard.routable_model?(self)
        conn = SchemaShard.active_connection
        return conn if conn
      end

      super
    end

    def connection_pool
      if SchemaShard.routable_model?(self)
        pool = SchemaShard.active_pool
        return pool if pool
      end

      super
    end
  end
end
