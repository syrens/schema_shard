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
        return false unless shard_cfg.is_a?(Hash)

        db  = (shard_cfg['database'] || shard_cfg[:database]).to_s
        url = (shard_cfg['url'] || shard_cfg[:url]).to_s
        db.include?('%{tenant}') || url.include?('%{tenant}')
      end

      def resolve_shard_config(shard_cfg, tenant: nil)
        return shard_cfg unless per_tenant_pool?(shard_cfg)

        tenant_str = tenant.to_s.strip
        unless present_value?(tenant_str) && valid_tenant_identifier?(tenant_str)
          raise InvalidTenantError,
                "SQLite per-tenant database template requires a valid tenant name (got #{tenant.inspect})"
        end

        updated = shard_cfg.transform_keys(&:to_s)
        updated['database'] = updated['database'].gsub('%{tenant}') { tenant_str } if updated['database']
        updated['url']      = updated['url'].gsub('%{tenant}') { tenant_str } if updated['url']
        updated
      end

      # SQLite isolates tenants via per-tenant database files (%{tenant} template).
      # Fail closed if a tenant is requested on a shared non-template SQLite shard.
      def switch_namespace(_conn, _tenant, persistent_schemas: [], shard_config: nil) # rubocop:disable Lint/UnusedMethodArgument
        unless per_tenant_pool?(shard_config)
          raise ConfigurationError,
                "SQLite shard does not use a '%{tenant}' database template; " \
                'use SchemaShard.on_shard for shard-only routing or configure a per-tenant template'
        end

        yield
      end

      def default_namespace_for(_shard_cfg, configured_default: nil) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      def non_idle_transaction?(conn)
        return true if conn.respond_to?(:open_transactions) && conn.open_transactions.to_i.positive?

        if conn.respond_to?(:raw_connection)
          raw = conn.raw_connection
          return true if raw.nil?
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
