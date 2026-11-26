# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module DatabaseAdapters
    class Mysql < Base
      VALID_MYSQL_DB_REGEX = /\A[a-zA-Z_][a-zA-Z0-9_-]{0,63}\z/
      FORBIDDEN_DATABASES  = %w[mysql information_schema performance_schema sys].freeze

      def default_pool_options(configuration)
        {
          'adapter' => 'trilogy',
          'encoding' => 'utf8mb4',
          'pool' => configuration.default_pool_size,
          'checkout_timeout' => configuration.checkout_timeout,
          'reaping_frequency' => configuration.reaping_frequency
        }
      end

      def apply_read_only_config(merged_config)
        updated = merged_config.dup
        vars = updated['variables'].is_a?(Hash) ? updated['variables'].transform_keys(&:to_s) : {}
        vars['transaction_read_only'] = 1
        updated['variables'] = vars
        updated
      end

      def non_idle_transaction?(conn)
        return true if conn.respond_to?(:open_transactions) && conn.open_transactions.to_i.positive?

        if conn.respond_to?(:select_value)
          in_tx = conn.select_value('SELECT @@in_transaction').to_i
          return in_tx.positive?
        end

        false
      rescue StandardError
        true
      end

      def switch_namespace(conn, tenant, persistent_schemas: []) # rubocop:disable Lint/UnusedMethodArgument
        previous_db = current_namespace(conn, live: true)
        use_database!(conn, tenant)
        yield
      ensure
        use_database!(conn, previous_db) if present_value?(previous_db)
      end

      def current_namespace(conn, live: false)
        return conn.select_value('SELECT DATABASE()')&.to_s if live && conn.respond_to?(:select_value)

        return conn.current_database.to_s if conn.respond_to?(:current_database)

        nil
      rescue StandardError
        nil
      end

      def verify_and_restore_namespace!(conn, expected_tenant:, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        actual = current_namespace(conn, live: live)
        return if actual == expected_tenant

        use_database!(conn, expected_tenant)
      end

      def verify_and_reset_default_namespace!(conn, default_namespace:, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        return unless present_value?(default_namespace)

        actual = current_namespace(conn, live: live)
        raise TaintedConnectionError, 'unverifiable MySQL database' if actual.nil?
        return if actual == default_namespace

        use_database!(conn, default_namespace)
      end

      def default_namespace_for(shard_cfg, configured_default: nil)
        shard_cfg['database'] || shard_cfg[:database] || configured_default
      end

      protected

      def default_adapter_name
        'trilogy'
      end

      def valid_tenant_identifier?(str)
        VALID_MYSQL_DB_REGEX.match?(str)
      end

      def forbidden_tenant?(str)
        FORBIDDEN_DATABASES.include?(str.downcase)
      end

      private

      def use_database!(conn, db_name)
        quoted = "`#{db_name.to_s.gsub('`', '``')}`"
        conn.execute("USE #{quoted}")
      end
    end

    register('mysql2', Mysql.instance)
    register('trilogy', Mysql.instance)
  end
end
