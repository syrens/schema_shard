# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module TenantAdapters
    # Zero-dependency tenant switcher delegating directly to the shard's DatabaseAdapter
    # (PostgreSQL `search_path`, MySQL `USE db`, SQLite per-tenant DB file).
    class Native < Base
      def switch(tenant, conn:, db_adapter:, &)
        db_adapter.switch_namespace(conn, tenant, persistent_schemas: persistent_schemas, &)
      end

      def current(conn:, db_adapter:) # rubocop:disable Lint/UnusedMethodArgument
        ExecutionContext.current_tenant
      end
    end
  end
end
