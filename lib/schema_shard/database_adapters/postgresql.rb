# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module DatabaseAdapters
    class Postgresql < Base
      FORBIDDEN_SCHEMA_PREFIXES = %w[pg_].freeze
      FORBIDDEN_SCHEMAS         = %w[information_schema].freeze

      def supports_namespaces?
        true
      end

      def apply_read_only_config(merged_config)
        updated = merged_config.dup
        vars = updated['variables'].is_a?(Hash) ? updated['variables'].transform_keys(&:to_s) : {}
        vars['default_transaction_read_only'] = 'on'
        updated['variables'] = vars
        updated
      end

      # Fails CLOSED: returns true (non-idle / unsafe) whenever PG transaction status cannot be verified.
      def non_idle_transaction?(conn)
        return true unless defined?(PG::PQTRANS_IDLE)
        return true unless conn.respond_to?(:raw_connection)

        raw = conn.raw_connection
        return true unless raw.respond_to?(:transaction_status)

        raw.transaction_status != PG::PQTRANS_IDLE
      rescue StandardError
        true
      end

      def switch_namespace(conn, tenant, persistent_schemas: [], shard_config: nil) # rubocop:disable Lint/UnusedMethodArgument
        previous_path  = conn.respond_to?(:schema_search_path) ? conn.schema_search_path : nil
        target_schemas = ([tenant] + Array(persistent_schemas).map(&:to_s)).uniq
        switched       = false
        in_flight      = false

        formatted = format_search_path(target_schemas)
        apply_search_path!(conn, formatted)
        switched = true

        begin
          conn.clear_cache! if conn.respond_to?(:clear_cache!)
          yield
        rescue Exception # rubocop:disable Lint/RescueException
          in_flight = true
          raise
        end
      ensure
        restore_search_path(conn, previous_path, suppress_errors: in_flight) if switched
      end

      def current_namespace(conn, live: false)
        return conn.select_value('SHOW search_path').to_s if live && conn.respond_to?(:select_value)
        return conn.schema_search_path.to_s if conn.respond_to?(:schema_search_path)

        nil
      rescue StandardError
        nil
      end

      def namespace_matches?(conn, expected_tenant, persistent_schemas: [], live: false)
        actual_path = current_namespace(conn, live: live)
        return false if actual_path.nil?

        expected = ([expected_tenant] + Array(persistent_schemas).map(&:to_s)).uniq
        search_path_matches?(actual_path, expected)
      end

      def verify_and_restore_namespace!(conn, expected_tenant:, persistent_schemas: [], live: false)
        actual_path = current_namespace(conn, live: live)
        expected    = ([expected_tenant] + Array(persistent_schemas).map(&:to_s)).uniq

        return if actual_path && search_path_matches?(actual_path, expected)

        apply_search_path!(conn, format_search_path(expected))
      end

      def verify_and_reset_default_namespace!(conn, default_namespace:, persistent_schemas: [], live: false)
        expected    = ([default_namespace || 'public'] + Array(persistent_schemas).map(&:to_s)).uniq
        actual_path = current_namespace(conn, live: live)

        raise TaintedConnectionError, 'unverifiable search_path' if actual_path.nil?
        return if search_path_matches?(actual_path, expected)

        apply_search_path!(conn, format_search_path(expected))
      end

      def default_namespace_for(_shard_cfg, configured_default: nil)
        configured_default || 'public'
      end

      def format_search_path(schemas)
        schemas.map do |s|
          str = s.to_s.strip
          unless valid_tenant_identifier?(str)
            raise InvalidTenantError, "Invalid schema identifier in search_path: #{s.inspect}"
          end

          %("#{str.gsub('"', '""')}")
        end.join(', ')
      end

      def search_path_matches?(current_path, expected_schemas)
        tokens = current_path.to_s.split(',').map { |s| s.delete('"').strip }.reject(&:empty?)
        return true if tokens == expected_schemas

        # PostgreSQL's built-in default "$user, public" is acceptable ONLY when the
        # expected default is strictly ["public"] with no persistent schemas.
        expected_schemas == ['public'] && tokens == ['$user', 'public']
      end

      protected

      def default_adapter_name
        'postgresql'
      end

      def forbidden_tenant?(str)
        downcased = str.downcase
        FORBIDDEN_SCHEMAS.include?(downcased) || FORBIDDEN_SCHEMA_PREFIXES.any? { |p| downcased.start_with?(p) }
      end

      private

      # Rails 8's PostgreSQLAdapter#schema_search_path= skips executing SET search_path
      # when its cached @schema_search_path already equals the target string. Force raw
      # SET search_path in that case so out-of-band SQL SET search_path mutations are overwritten.
      def apply_search_path!(conn, formatted)
        cached = conn.respond_to?(:schema_search_path) ? conn.schema_search_path : nil
        if cached == formatted && conn.respond_to?(:execute)
          conn.execute("SET search_path TO #{formatted}")
        else
          conn.schema_search_path = formatted
        end
      end

      def restore_search_path(conn, previous_path, suppress_errors: false)
        return unless previous_path && conn.respond_to?(:schema_search_path=)

        apply_search_path!(conn, previous_path)
        conn.clear_cache! if conn.respond_to?(:clear_cache!)
      rescue StandardError
        # Do not mask an in-flight exception (e.g. Timeout::Error / PG::InFailedSqlTransaction);
        # ConnectionSanitizer will perform live verification and discard the connection fail-closed.
        raise unless suppress_errors
      end
    end

    register('postgresql', Postgresql.instance)
    register('postgis', Postgresql.instance)
  end
end
