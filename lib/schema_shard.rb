# frozen_string_literal: true

require 'active_support'
require 'active_support/isolated_execution_state'
require 'active_record'

require_relative 'schema_shard/version'
require_relative 'schema_shard/errors'
require_relative 'schema_shard/configuration'
require_relative 'schema_shard/database_adapters/base'
require_relative 'schema_shard/database_adapters/postgresql'
require_relative 'schema_shard/database_adapters/mysql'
require_relative 'schema_shard/database_adapters/sqlite'
require_relative 'schema_shard/database_adapters/generic'
require_relative 'schema_shard/tenant_adapters/base'
require_relative 'schema_shard/tenant_adapters/apartment'
require_relative 'schema_shard/tenant_adapters/native'
require_relative 'schema_shard/tenant_adapters/none'
require_relative 'schema_shard/config_loader'
require_relative 'schema_shard/execution_context'
require_relative 'schema_shard/pool_entry'
require_relative 'schema_shard/metrics'
require_relative 'schema_shard/pool_registry'
require_relative 'schema_shard/connection_sanitizer'
require_relative 'schema_shard/connection_patch'
require_relative 'schema_shard/middleware/sidekiq'
require_relative 'schema_shard/query_logger'
require_relative 'schema_shard/railtie' if defined?(Rails::Railtie)

module SchemaShard
  module ForkHook
    def _fork
      pid = super
      SchemaShard.discard_pools_after_fork! if pid.zero?
      pid
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
      @config_loader = nil
      @pool_registry = nil
      @sanitizer     = nil
      @metrics_store = nil
      configuration
    end

    def install!
      return if ActiveRecord::Base.singleton_class.ancestors.include?(ConnectionPatch)

      ActiveRecord::Base.singleton_class.prepend(ConnectionPatch)
    end

    def install_fork_hook!
      return if @fork_hook_installed
      return unless Process.respond_to?(:_fork)

      Process.singleton_class.prepend(ForkHook)
      @fork_hook_installed = true
    end

    # Executes a block within a shard (and optionally a tenant schema/database).
    #
    # @param tenant       [String, nil] Tenant schema/database name (optional when tenant_mode is :optional or :none)
    # @param shard_key    [String, Symbol, nil] Key from shards.yml (falls back to configuration.default_shard)
    # @param allow_public [Boolean] Allow default schema/namespace in :strict mode (default: false)
    # @param read_only    [Boolean] Enforce read-only replica protections (default: true)
    def with(tenant = nil, shard_key: nil, allow_public: false, read_only: true, &)
      raise ArgumentError, 'Block is required' unless block_given?

      normalized_shard = resolve_shard_key!(shard_key)
      shard_config     = config_loader.fetch!(normalized_shard)
      db_adapter       = DatabaseAdapters.for(shard_config['adapter'] || shard_config[:adapter])
      tenant_adapter   = TenantAdapters.resolve(configuration)

      normalized_tenant = resolve_tenant!(
        tenant,
        shard_config: shard_config,
        db_adapter: db_adapter,
        tenant_adapter: tenant_adapter,
        allow_public: allow_public
      )

      execute_in_shard(
        shard_key: normalized_shard,
        shard_config: shard_config,
        tenant: normalized_tenant,
        db_adapter: db_adapter,
        tenant_adapter: tenant_adapter,
        read_only: read_only,
        &
      )
    end

    # Explicit shard-only routing with NO tenant/schema switching.
    # Falls back to the shard's default schema/database regardless of tenant_mode.
    def on_shard(shard_key = nil, read_only: true, &)
      raise ArgumentError, 'Block is required' unless block_given?

      normalized_shard = resolve_shard_key!(shard_key)
      shard_config     = config_loader.fetch!(normalized_shard)
      db_adapter       = DatabaseAdapters.for(shard_config['adapter'] || shard_config[:adapter])
      none_adapter     = TenantAdapters::None.new(configuration)

      execute_in_shard(
        shard_key: normalized_shard,
        shard_config: shard_config,
        tenant: nil,
        db_adapter: db_adapter,
        tenant_adapter: none_adapter,
        read_only: read_only,
        &
      )
    end

    # Explicitly executes a block against the default (`public`) schema on a shard.
    def with_public(shard_key: nil, read_only: true, &)
      tenant_adapter = TenantAdapters.resolve(configuration)
      with(
        tenant_adapter.default_namespace,
        shard_key: shard_key,
        allow_public: true,
        read_only: read_only,
        &
      )
    end

    # Execution state readers
    def current_config      = ExecutionContext.current_config
    def current_shard_label = ExecutionContext.current_shard_label
    def current_tenant      = ExecutionContext.current_tenant
    def active_connection   = ExecutionContext.active_connection
    def active_pool         = ExecutionContext.active_pool

    def routable_model?(klass)
      return true if klass == ActiveRecord::Base
      return false if excluded_model?(klass)
      return false if custom_connection_model?(klass)

      true
    end

    def clear_thread_locals!
      ExecutionContext.clear!(logger: configuration.effective_logger)
    end

    def reload_config!
      config_loader.reload!
      pool_registry.clear_key_cache!
      pool_registry.cleanup_unused_pools!
      nil
    end

    def discard_pools_after_fork!
      pool_registry.discard_pools_after_fork!
      clear_thread_locals!
      nil
    end

    # Pool management & monitoring API
    def pool_count               = pool_registry.pool_count
    def pool_usage_info          = pool_registry.pool_usage_info
    def pool_statistics          = pool_registry.pool_statistics
    def total_active_connections = pool_registry.total_active_connections
    def cleanup_connection_pools! = pool_registry.cleanup_connection_pools!
    def cleanup_unused_pools!     = pool_registry.cleanup_unused_pools!

    # Observability API
    def metrics
      metrics_store.snapshot(pool_status: pool_registry.pool_status_snapshot)
    end

    def prometheus_metrics
      metrics_store.prometheus(pool_status: pool_registry.pool_status_snapshot)
    end

    def statsd_metrics
      metrics_store.statsd(pool_status: pool_registry.pool_status_snapshot)
    end

    def reset_metrics!
      metrics_store.reset!
    end

    def increment_metric(metric_name, count = 1)
      metrics_store.increment(metric_name, count)
    end

    def increment_shard_metric(shard_key, metric_name, count = 1)
      metrics_store.increment_shard(shard_key, metric_name, count)
    end

    # Internal collaborators (accessible for testing)
    def config_loader
      @config_loader ||= ConfigLoader.new(configuration: configuration)
    end

    def pool_registry
      @pool_registry ||= PoolRegistry.new(configuration: configuration, metrics: metrics_store)
    end

    def metrics_store
      @metrics_store ||= Metrics.new
    end

    def sanitizer
      @sanitizer ||= ConnectionSanitizer.new(configuration: configuration, metrics: metrics_store)
    end

    private

    def execute_in_shard(shard_key:, shard_config:, tenant:, db_adapter:, tenant_adapter:, read_only:, &block)
      if same_active_context?(shard_key, tenant, read_only, tenant_adapter, db_adapter)
        metrics_store.track_switch(shard_key)
        return yield
      end

      metrics_store.track_switch(shard_key)
      entry        = pool_registry.acquire(shard_config, shard_key, db_adapter: db_adapter,
                                                                    read_only: read_only, tenant: tenant)
      outer_tenant = ExecutionContext.current_tenant

      begin
        with_read_only_guard(read_only) do
          ExecutionContext.with_context(shard_key: shard_key, config: shard_config,
                                        tenant: tenant, read_only: read_only) do
            scope = {
              shard_key: shard_key, shard_config: shard_config, tenant: tenant,
              outer_tenant: outer_tenant, db_adapter: db_adapter,
              tenant_adapter: tenant_adapter, read_only: read_only
            }
            with_pool_scope(entry.pool, scope, &block)
          end
        end
      ensure
        entry.release
      end
    end

    def resolve_shard_key!(shard_key)
      resolved = shard_key.nil? ? configuration.default_shard : shard_key
      if resolved.nil? || resolved.to_s.strip.empty?
        raise ArgumentError, 'shard_key is required (or configure SchemaShard.configuration.default_shard)'
      end

      resolved.to_s
    end

    def resolve_tenant!(tenant, shard_config:, db_adapter:, tenant_adapter:, allow_public:)
      return nil unless tenant_adapter.switches_tenant?

      return nil if tenant.nil? && configuration.tenant_mode == :optional

      effective_allow_public = allow_public || configuration.tenant_mode == :optional
      default_ns = tenant_adapter.default_namespace(shard_config, db_adapter: db_adapter)

      db_adapter.validate_tenant!(tenant, default_namespace: default_ns, allow_public: effective_allow_public)
    end

    def same_active_context?(shard_key, tenant, read_only, tenant_adapter, db_adapter)
      conn = ExecutionContext.active_connection
      return false if conn.nil?
      return false unless ExecutionContext.current_shard_label == shard_key
      return false unless ExecutionContext.current_tenant == tenant
      return false unless ExecutionContext.read_only? == read_only

      if tenant && tenant_adapter.switches_tenant?
        live_current = tenant_adapter.current(conn: conn, db_adapter: db_adapter)
        return false if live_current && live_current.to_s != tenant
      end

      true
    end

    def with_read_only_guard(read_only, &)
      if read_only && ActiveRecord::Base.respond_to?(:while_preventing_writes)
        ActiveRecord::Base.while_preventing_writes(&)
      else
        yield
      end
    end

    def with_pool_scope(pool, scope, &block)
      prev_conn = ExecutionContext.active_connection
      prev_pool = ExecutionContext.active_pool

      pool.with_connection do |conn|
        metrics_store.increment(:connection_checkouts_total)
        reentrant = prev_conn.equal?(conn) && prev_pool.equal?(pool)
        run_on_connection(pool, conn, scope, reentrant: reentrant, &block)
      end
    rescue ActiveRecord::ConnectionTimeoutError => e
      metrics_store.increment(:connection_timeouts_total)
      configuration.effective_logger&.error "[SchemaShard] Checkout timeout for #{scope[:shard_key]}: #{e.message}"
      raise
    rescue ActiveRecord::ConnectionNotEstablished => e
      metrics_store.increment(:connection_verification_failures_total)
      metrics_store.increment_shard(scope[:shard_key], :verification_failures_total)
      configuration.effective_logger&.error "[SchemaShard] Connection failed for #{scope[:shard_key]}: #{e.message}"
      raise
    end

    def run_on_connection(pool, conn, scope, reentrant:, &block)
      block_raised    = false
      tenant_switched = !scope[:tenant].nil? && scope[:tenant_adapter].switches_tenant?

      begin
        scope[:db_adapter].prepare_connection(conn, read_only: scope[:read_only])
        ExecutionContext.with_connection(conn, pool) do
          sanitizer.clear_query_cache!(pool, conn)
          if tenant_switched
            scope[:tenant_adapter].switch(scope[:tenant], conn: conn, db_adapter: scope[:db_adapter], &block)
          else
            yield
          end
        end
      rescue Exception # rubocop:disable Lint/RescueException
        block_raised = true
        raise
      ensure
        cleanup_after_connection(pool, conn, scope, reentrant: reentrant,
                                                    tenant_switched: tenant_switched, block_raised: block_raised)
      end
    end

    def cleanup_after_connection(pool, conn, scope, reentrant:, tenant_switched:, block_raised:)
      sanitizer.clear_query_cache!(pool, conn)
      if reentrant
        sanitizer.verify_nested_clean!(
          pool, conn,
          shard_key: scope[:shard_key], db_adapter: scope[:db_adapter],
          tenant_adapter: scope[:tenant_adapter], outer_tenant: scope[:outer_tenant],
          verify_live: block_raised
        )
      else
        sanitizer.sanitize_before_checkin(
          pool, conn,
          shard_key: scope[:shard_key], db_adapter: scope[:db_adapter],
          tenant_adapter: scope[:tenant_adapter], shard_config: scope[:shard_config],
          tenant_switched: tenant_switched, verify_live: block_raised
        )
      end
    end

    def excluded_model?(klass)
      excluded_set = TenantAdapters.resolve(configuration).excluded_models
      return false if excluded_set.empty?

      klass.ancestors.any? do |ancestor|
        ancestor.is_a?(Class) && ancestor < ActiveRecord::Base && excluded_set.include?(ancestor.name)
      end
    end

    def custom_connection_model?(klass)
      return false unless klass.respond_to?(:connection_class?) && klass.connection_class?
      return false if defined?(ApplicationRecord) && klass == ApplicationRecord

      true
    end
  end
end
