# frozen_string_literal: true

module SchemaShard
  module TenantAdapters
    def self.resolve(configuration)
      return None.new(configuration) if configuration.tenant_mode == :none

      case configuration.tenant_adapter
      when :auto
        if defined?(::Apartment::Tenant)
          Apartment.new(configuration)
        else
          Native.new(configuration)
        end
      when :apartment
        Apartment.new(configuration)
      when :native, :postgresql_schema
        Native.new(configuration)
      when :none
        None.new(configuration)
      else
        configuration.tenant_adapter
      end
    end

    class Base
      def initialize(configuration)
        @configuration = configuration
      end

      def switches_tenant?
        true
      end

      def switch(_tenant, conn:, db_adapter:, shard_config: nil) # rubocop:disable Lint/UnusedMethodArgument
        yield
      end

      def current(conn:, db_adapter:) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      def matches_current?(tenant, conn:, db_adapter:)
        live = current(conn: conn, db_adapter: db_adapter)
        live.nil? || live.to_s == tenant.to_s
      end

      def default_namespace(shard_config = nil, db_adapter: nil)
        if db_adapter && shard_config
          db_adapter.default_namespace_for(shard_config, configured_default: @configuration.default_schema)
        else
          @configuration.default_schema.to_s
        end
      end

      def persistent_schemas
        Array(@configuration.persistent_schemas).map(&:to_s)
      end

      def excluded_models
        Array(@configuration.excluded_models).map(&:to_s)
      end
    end
  end
end
