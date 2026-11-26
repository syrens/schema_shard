# frozen_string_literal: true

module SchemaShard
  module DatabaseAdapters
    @registry = {}
    @mutex = Mutex.new

    class << self
      def register(name, adapter)
        @mutex.synchronize do
          @registry[name.to_s.downcase] = adapter
        end
      end

      def for(adapter_name)
        key = adapter_name.to_s.downcase
        key = 'postgresql' if key.empty?

        @mutex.synchronize { @registry[key] } || Generic.instance
      end
    end

    class Base
      VALID_IDENTIFIER_REGEX = /\A[a-zA-Z_][a-zA-Z0-9_-]{0,62}\z/

      def self.instance
        @instance ||= new
      end

      def supports_namespaces?
        false
      end

      def validate_config!(shard_key, shard_cfg)
        has_url = present_value?(shard_cfg['url'] || shard_cfg[:url])
        has_host_and_db = present_value?(shard_cfg['host'] || shard_cfg[:host]) &&
                          present_value?(shard_cfg['database'] || shard_cfg[:database])

        return if has_url || has_host_and_db

        raise ArgumentError,
              "Shard '#{shard_key}' must explicitly configure either 'url' or both 'host' and 'database'"
      end

      def validate_tenant!(tenant, default_namespace:, allow_public: false)
        if tenant.nil?
          raise InvalidTenantError,
                'Tenant name cannot be nil; use SchemaShard.on_shard or SchemaShard.with_public if default is intended'
        end

        str = tenant.to_s.strip
        if str.empty?
          raise InvalidTenantError, 'Tenant name cannot be blank; refusing to fall back to default namespace'
        end

        raise InvalidTenantError, "Invalid tenant name: #{str.inspect}" unless valid_tenant_identifier?(str)
        raise InvalidTenantError, "Forbidden system namespace: #{str.inspect}" if forbidden_tenant?(str)

        if default_namespace && str.casecmp?(default_namespace.to_s) && !allow_public
          raise InvalidTenantError,
                "Default namespace '#{str}' requires explicit allow_public: true or SchemaShard.with_public"
        end

        str
      end

      def default_pool_options(configuration)
        {
          'adapter' => default_adapter_name,
          'encoding' => 'unicode',
          'pool' => configuration.default_pool_size,
          'checkout_timeout' => configuration.checkout_timeout,
          'reaping_frequency' => configuration.reaping_frequency
        }
      end

      def apply_read_only_config(merged_config)
        merged_config
      end

      def prepare_connection(_conn, read_only: true) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      def per_tenant_pool?(_shard_cfg)
        false
      end

      def resolve_shard_config(shard_cfg, tenant: nil) # rubocop:disable Lint/UnusedMethodArgument
        shard_cfg
      end

      def non_idle_transaction?(conn)
        return false unless conn.respond_to?(:open_transactions)

        conn.open_transactions.to_i.positive?
      rescue StandardError
        true
      end

      # Fail closed: adapters that do not implement tenant isolation must NOT silently
      # execute tenant-scoped queries against a shared database.
      def switch_namespace(_conn, _tenant, persistent_schemas: [], shard_config: nil) # rubocop:disable Lint/UnusedMethodArgument
        raise ConfigurationError,
              "#{self.class.name} does not support tenant namespace switching; " \
              'use SchemaShard.on_shard, set tenant_mode: :none, or register a custom adapter'
      end

      def current_namespace(_conn, live: false) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      def namespace_matches?(_conn, _expected_tenant, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        true
      end

      def verify_and_restore_namespace!(_conn, expected_tenant:, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      def verify_and_reset_default_namespace!(_conn, default_namespace:, persistent_schemas: [], live: false) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      def default_namespace_for(shard_cfg, configured_default: nil)
        configured_default || shard_cfg['database'] || shard_cfg[:database]
      end

      protected

      def default_adapter_name
        'postgresql'
      end

      def valid_tenant_identifier?(str)
        VALID_IDENTIFIER_REGEX.match?(str)
      end

      def forbidden_tenant?(_str)
        false
      end

      def present_value?(value)
        !value.nil? && !value.to_s.strip.empty?
      end
    end
  end
end
