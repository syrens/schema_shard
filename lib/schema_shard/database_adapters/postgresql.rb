# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module DatabaseAdapters
    class Postgresql < Base
      FORBIDDEN_SCHEMA_PREFIXES = %w[pg_].freeze
      FORBIDDEN_SCHEMAS         = %w[information_schema].freeze

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

      def switch_namespace(conn, tenant, persistent_schemas: [])
        previous_path = conn.respond_to?(:schema_search_path) ? conn.schema_search_path : nil
        target_schemas = ([tenant] + Array(persistent_schemas).map(&:to_s)).uniq
        conn.schema_search_path = format_search_path(target_schemas)
        yield
      ensure
        conn.schema_search_path = previous_path if previous_path && conn.respond_to?(:schema_search_path=)
      end

      def current_namespace(conn, live: false)
        return conn.select_value('SHOW search_path').to_s if live && conn.respond_to?(:select_value)

        return conn.schema_search_path.to_s if conn.respond_to?(:schema_search_path)

        nil
      rescue StandardError
        nil
      end

      def verify_and_restore_namespace!(conn, expected_tenant:, persistent_schemas: [], live: false)
        actual_path = current_namespace(conn, live: live)
        expected    = ([expected_tenant] + Array(persistent_schemas).map(&:to_s)).uniq

        return if actual_path && search_path_matches?(actual_path, expected)

        conn.schema_search_path = format_search_path(expected)
      end

      def verify_and_reset_default_namespace!(conn, default_namespace:, persistent_schemas: [], live: false)
        expected    = ([default_namespace || 'public'] + Array(persistent_schemas).map(&:to_s)).uniq
        actual_path = current_namespace(conn, live: live)

        raise TaintedConnectionError, 'unverifiable search_path' if actual_path.nil?
        return if search_path_matches?(actual_path, expected)

        conn.schema_search_path = format_search_path(expected)
      end

      def default_namespace_for(_shard_cfg, configured_default: nil)
        configured_default || 'public'
      end

      def format_search_path(schemas)
        schemas.map { |s| %("#{s}") }.join(', ')
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
    end

    register('postgresql', Postgresql.instance)
    register('postgis', Postgresql.instance)
  end
end
