# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module DatabaseAdapters
    class Mysql < Base
      VALID_MYSQL_DB_REGEX = /\A[a-zA-Z_][a-zA-Z0-9_-]{0,63}\z/
      FORBIDDEN_DATABASES  = %w[mysql information_schema performance_schema sys].freeze
      SERVER_STATUS_IN_TRANS = 0x0001

      def supports_namespaces?
        true
      end

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

        raw_state = check_raw_transaction_state(conn)
        return raw_state unless raw_state.nil?

        mariadb_in_transaction?(conn)
      rescue StandardError
        true
      end

      def switch_namespace(conn, tenant, persistent_schemas: [], shard_config: nil) # rubocop:disable Lint/UnusedMethodArgument
        previous_db = current_namespace(conn, live: true)
        switched    = false
        in_flight   = false

        use_database!(conn, tenant)
        switched = true

        begin
          conn.clear_cache! if conn.respond_to?(:clear_cache!)
          yield
        rescue Exception # rubocop:disable Lint/RescueException
          in_flight = true
          raise
        end
      ensure
        restore_database(conn, previous_db, suppress_errors: in_flight) if switched
      end

      def current_namespace(conn, live: false)
        return conn.select_value('SELECT DATABASE()')&.to_s if live && conn.respond_to?(:select_value)
        return conn.current_database.to_s if conn.respond_to?(:current_database)

        nil
      rescue StandardError
        nil
      end

      def namespace_matches?(conn, expected_tenant, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        actual = current_namespace(conn, live: live)
        !actual.nil? && actual.casecmp?(expected_tenant.to_s)
      end

      def verify_and_restore_namespace!(conn, expected_tenant:, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        actual = current_namespace(conn, live: live)
        return if actual&.casecmp?(expected_tenant.to_s)

        use_database!(conn, expected_tenant)
      end

      def verify_and_reset_default_namespace!(conn, default_namespace:, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        unless present_value?(default_namespace)
          raise TaintedConnectionError, 'cannot reset MySQL database: default_namespace is blank'
        end

        actual = current_namespace(conn, live: live)
        raise TaintedConnectionError, 'unverifiable MySQL database' if actual.nil?
        return if actual.casecmp?(default_namespace.to_s)

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

      def check_raw_transaction_state(conn)
        return nil unless conn.respond_to?(:raw_connection)

        raw = conn.raw_connection
        return true if raw.nil?
        return raw.server_status.to_i.anybits?(SERVER_STATUS_IN_TRANS) if raw.respond_to?(:server_status)
        return raw.in_transaction? if raw.respond_to?(:in_transaction?)
        return nil unless defined?(::Trilogy::Result) && raw.respond_to?(:query)

        res = raw.query('SELECT 1')
        res.respond_to?(:in_transaction?) ? res.in_transaction? : nil
      end

      def mariadb_in_transaction?(conn)
        return false unless conn.respond_to?(:mariadb?) && conn.mariadb? && conn.respond_to?(:select_value)

        conn.select_value('SELECT @@in_transaction').to_i.positive?
      end

      def use_database!(conn, db_name)
        quoted = "`#{db_name.to_s.gsub('`', '``')}`"
        conn.execute("USE #{quoted}")
      end

      def restore_database(conn, previous_db, suppress_errors: false)
        return unless present_value?(previous_db)

        use_database!(conn, previous_db)
        conn.clear_cache! if conn.respond_to?(:clear_cache!)
      rescue StandardError
        raise unless suppress_errors
      end
    end

    register('mysql2', Mysql.instance)
    register('trilogy', Mysql.instance)
  end
end
