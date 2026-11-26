# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module TenantAdapters
    # Zero-dependency tenant switcher delegating directly to the shard's DatabaseAdapter
    # (PostgreSQL `search_path`, MySQL `USE db`, SQLite per-tenant DB file).
    class Native < Base
      def switch(tenant, conn:, db_adapter:, shard_config: nil, &)
        db_adapter.switch_namespace(
          conn,
          tenant,
          persistent_schemas: persistent_schemas,
          shard_config: shard_config,
          &
        )
      end

      def current(conn:, db_adapter:)
        db_adapter.current_namespace(conn, live: false)
      end

      def matches_current?(tenant, conn:, db_adapter:, live: false)
        db_adapter.namespace_matches?(conn, tenant, persistent_schemas: persistent_schemas, live: live)
      end
    end
  end
end
