# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module DatabaseAdapters
    class Sqlite < Base
      VALID_SQLITE_TENANT_REGEX = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/

      def validate_config!(shard_key, shard_cfg)
        has_url = present_value?(shard_cfg['url'] || shard_cfg[:url])
        has_db  = present_value?(shard_cfg['database'] || shard_cfg[:database])
        return if has_url || has_db

        raise ArgumentError, "SQLite shard '#{shard_key}' must explicitly configure 'database' or 'url'"
      end

      def default_pool_options(configuration)
        {
          'adapter' => 'sqlite3',
          'pool' => configuration.default_pool_size,
          'checkout_timeout' => configuration.checkout_timeout,
          'reaping_frequency' => configuration.reaping_frequency
        }
      end

      def prepare_connection(conn, read_only: true)
        return unless conn.respond_to?(:execute)

        conn.execute("PRAGMA query_only = #{read_only ? 'ON' : 'OFF'}")
      end

      def per_tenant_pool?(shard_cfg)
        db = (shard_cfg['database'] || shard_cfg[:database]).to_s
        db.include?('%{tenant}')
      end

      def resolve_shard_config(shard_cfg, tenant: nil)
        return shard_cfg unless per_tenant_pool?(shard_cfg)

        unless present_value?(tenant)
          raise InvalidTenantError, 'SQLite per-tenant database template requires a tenant name'
        end

        updated = shard_cfg.transform_keys(&:to_s)
        updated['database'] = updated['database'].gsub('%{tenant}', tenant.to_s)
        updated
      end

      def non_idle_transaction?(conn)
        return true if conn.respond_to?(:open_transactions) && conn.open_transactions.to_i.positive?

        if conn.respond_to?(:raw_connection)
          raw = conn.raw_connection
          return true if raw.respond_to?(:transaction_active?) && raw.transaction_active?
        end

        false
      rescue StandardError
        true
      end

      protected

      def default_adapter_name
        'sqlite3'
      end

      def valid_tenant_identifier?(str)
        VALID_SQLITE_TENANT_REGEX.match?(str)
      end
    end

    register('sqlite3', Sqlite.instance)
  end
end
