# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module TenantAdapters
    class Apartment < Base
      def switch(tenant, conn:, db_adapter:, shard_config: nil, &) # rubocop:disable Lint/UnusedMethodArgument
        ::Apartment::Tenant.switch(tenant, &)
      end

      def current(conn:, db_adapter:) # rubocop:disable Lint/UnusedMethodArgument
        return nil unless defined?(::Apartment::Tenant) && ::Apartment::Tenant.respond_to?(:current)

        ::Apartment::Tenant.current.to_s
      end

      def matches_current?(tenant, conn:, db_adapter:)
        super && db_adapter.namespace_matches?(conn, tenant, persistent_schemas: persistent_schemas)
      end

      def default_namespace(shard_config = nil, db_adapter: nil)
        if defined?(::Apartment) && ::Apartment.respond_to?(:default_schema) &&
           !::Apartment.default_schema.nil? && !::Apartment.default_schema.to_s.empty?
          ::Apartment.default_schema.to_s
        else
          super
        end
      end

      def persistent_schemas
        apt_schemas = if defined?(::Apartment) && ::Apartment.respond_to?(:persistent_schemas)
                        Array(::Apartment.persistent_schemas).map(&:to_s)
                      else
                        []
                      end
        (apt_schemas + super).uniq
      end

      def excluded_models
        apt_excluded = if defined?(::Apartment) && ::Apartment.respond_to?(:excluded_models)
                         Array(::Apartment.excluded_models).map(&:to_s)
                       else
                         []
                       end
        (apt_excluded + super).uniq
      end
    end
  end
end
