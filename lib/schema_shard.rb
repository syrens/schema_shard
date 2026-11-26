# frozen_string_literal: true

require 'active_support'
require 'active_support/isolated_execution_state'
require 'active_record' unless defined?(Rails::Railtie)

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
      @pool_registry&.cleanup_connection_pools!
      @configuration = Configuration.new
      @config_loader = nil
      @pool_registry = nil
      @sanitizer     = nil
      @metrics_store = nil
      @excluded_models_cache = nil
      configuration
    end

    def install!
      require 'active_record' unless defined?(ActiveRecord::Base)
      return if ActiveRecord::Base.singleton_class.ancestors.include?(ConnectionPatch)

      ActiveRecord::Base.singleton_class.prepend(ConnectionPatch)
    end

    def install_fork_hook!
      return if @fork_hook_installed
      return unless Process.respond_to?(:_fork)

      Process.singleton_class.prepend(ForkHook)
      @fork_hook_installed = true
    end

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

    def with_public(shard_key: nil, read_only: true, &)
      raise ArgumentError, 'Block is required' unless block_given?

      normalized_shard = resolve_shard_key!(shard_key)
      shard_config     = config_loader.fetch!(normalized_shard)
      db_adapter       = DatabaseAdapters.for(shard_config['adapter'] || shard_config[:adapter])
      tenant_adapter   = TenantAdapters.resolve(configuration)
      default_ns       = tenant_adapter.default_namespace(shard_config, db_adapter: db_adapter)

      with(default_ns, shard_key: normalized_shard, allow_public: true, read_only: read_only, &)
    end

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

    def pool_count                = pool_registry.pool_count
    def pool_usage_info           = pool_registry.pool_usage_info
    def pool_statistics           = pool_registry.pool_statistics
    def total_active_connections  = pool_registry.total_active_connections
    def cleanup_connection_pools! = pool_registry.cleanup_connection_pools!
    def cleanup_unused_pools!     = pool_registry.cleanup_unused_pools!

    def metrics            = metrics_store.snapshot(pool_status: pool_registry.pool_status_snapshot)
    def prometheus_metrics = metrics_store.prometheus(pool_status: pool_registry.pool_status_snapshot)
    def statsd_metrics     = metrics_store.statsd(pool_status: pool_registry.pool_status_snapshot)
    def reset_metrics!     = metrics_store.reset!

    def increment_metric(metric_name, count = 1)
      metrics_store.increment(metric_name, count)
    end

    def increment_shard_metric(shard_key, metric_name, count = 1)
      metrics_store.increment_shard(shard_key, metric_name, count)
    end

    def config_loader
      @config_loader ||= ConfigLoader.new(configuration: configuration)
    end

    def pool_registry
      @pool_registry ||= PoolRegistry.new(configuration: configuration, metrics: metrics_store)
    end

    def metrics_store
      @metrics_store ||= Metrics.new(configuration: configuration)
    end

    def sanitizer
      @sanitizer ||= ConnectionSanitizer.new(configuration: configuration, metrics: metrics_store)
    end

    private

    def execute_in_shard(shard_key:, shard_config:, tenant:, db_adapter:, tenant_adapter:, read_only:, &block)
      if same_active_context?(shard_key, shard_config, tenant, read_only, tenant_adapter, db_adapter)
        metrics_store.track_switch(shard_key)
        return yield
      end

      metrics_store.track_switch(shard_key)
      entry = nil

      begin
        entry = pool_registry.acquire(shard_config, shard_key, db_adapter: db_adapter,
                                                               read_only: read_only, tenant: tenant)
        with_read_only_guard(read_only) do
          ExecutionContext.with_context(shard_key: shard_key, config: shard_config,
                                        tenant: tenant, read_only: read_only) do
            scope = {
              shard_key: shard_key, shard_config: shard_config, tenant: tenant,
              db_adapter: db_adapter, tenant_adapter: tenant_adapter, read_only: read_only
            }
            with_pool_scope(entry.pool, scope, &block)
          end
        end
      ensure
        entry&.release
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

    def same_active_context?(shard_key, shard_config, tenant, read_only, tenant_adapter, db_adapter)
      conn = ExecutionContext.active_connection
      return false unless conn && context_metadata_matches?(shard_key, shard_config, tenant, read_only)

      live = configuration.live_verify_fast_path
      if tenant && tenant_adapter.switches_tenant?
        return tenant_adapter.matches_current?(tenant, conn: conn, db_adapter: db_adapter, live: live)
      end

      return true unless tenant.nil? && db_adapter.supports_namespaces?

      default_ns = tenant_adapter.default_namespace(shard_config, db_adapter: db_adapter)
      db_adapter.namespace_matches?(conn, default_ns, persistent_schemas: tenant_adapter.persistent_schemas, live: live)
    end

    def context_metadata_matches?(shard_key, shard_config, tenant, read_only)
      ExecutionContext.current_shard_label == shard_key &&
        ExecutionContext.current_config == shard_config &&
        ExecutionContext.current_tenant == tenant &&
        ExecutionContext.read_only? == read_only
    end

    def with_read_only_guard(read_only, &)
      if read_only && ActiveRecord::Base.respond_to?(:while_preventing_writes)
        ActiveRecord::Base.while_preventing_writes(&)
      elsif !read_only && ExecutionContext.read_only? == true
        raise ConfigurationError, 'Cannot open a writable shard block (read_only: false) inside a read-only block'
      else
        yield
      end
    end

    def with_pool_scope(pool, scope, &block)
      enclosing = ExecutionContext.enclosing_pool_frame(pool)
      if enclosing&.dig(:tainted)
        raise TaintedConnectionError, "Cannot open nested block on tainted shard pool '#{scope[:shard_key]}'"
      end

      reentrant = !enclosing.nil?

      checkout_connection(pool) do |conn|
        metrics_store.increment(:connection_checkouts_total)
        run_on_connection(pool, conn, scope, enclosing: enclosing, reentrant: reentrant, &block)
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

    def checkout_connection(pool, &)
      @checkout_cap_cache ||= Concurrent::Map.new
      supports_key = @checkout_cap_cache.compute_if_absent(pool.class) do
        params = pool.method(:with_connection).parameters
        params.any? { |type, name| type == :key && name == :prevent_permanent_checkout }
      end

      if supports_key
        pool.with_connection(prevent_permanent_checkout: true, &)
      else
        pool.with_connection(&)
      end
    end

    def run_on_connection(pool, conn, scope, enclosing:, reentrant:, &block)
      block_raised    = false
      tenant_switched = !scope[:tenant].nil? && scope[:tenant_adapter].switches_tenant?
      ExecutionContext.mark_pool_frames_dirty(pool) if reentrant && tenant_switched
      frame = ExecutionContext.push_pool_frame(pool, tenant: scope[:tenant], tenant_switched: tenant_switched)

      begin
        scope[:db_adapter].prepare_connection(conn, read_only: scope[:read_only])
        ExecutionContext.with_connection(conn, pool) do
          sanitizer.clear_query_cache!(pool, conn)
          if tenant_switched
            scope[:tenant_adapter].switch(
              scope[:tenant], conn: conn, db_adapter: scope[:db_adapter], shard_config: scope[:shard_config], &block
            )
          else
            yield
          end
        end
      rescue Exception # rubocop:disable Lint/RescueException
        block_raised = true
        raise
      ensure
        ExecutionContext.pop_pool_frame(pool)
        begin
          cleanup_after_connection(
            pool, conn, scope,
            enclosing: enclosing, reentrant: reentrant,
            tenant_switched: tenant_switched || frame[:dirty], block_raised: block_raised
          )
        ensure
          pool.release_connection if !reentrant && pool.respond_to?(:release_connection)
        end
      end
    end

    def cleanup_after_connection(pool, conn, scope, enclosing:, reentrant:, tenant_switched:, block_raised:)
      if reentrant
        sanitizer.clear_query_cache!(pool, conn)
        sanitizer.verify_nested_clean!(
          pool, conn,
          shard_key: scope[:shard_key], db_adapter: scope[:db_adapter],
          tenant_adapter: scope[:tenant_adapter], shard_config: scope[:shard_config],
          outer_tenant: enclosing[:tenant], tenant_switched: tenant_switched, verify_live: block_raised
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
      excluded_set = cached_excluded_models_set
      return false if excluded_set.empty?

      klass.ancestors.any? do |ancestor|
        ancestor.is_a?(Class) && ancestor < ActiveRecord::Base && excluded_set.include?(ancestor.name)
      end
    end

    def cached_excluded_models_set
      apt_excluded = (::Apartment.excluded_models if defined?(::Apartment) && ::Apartment.respond_to?(:excluded_models))
      cache_key = [
        configuration.tenant_adapter,
        configuration.tenant_mode,
        Array(configuration.excluded_models).dup,
        apt_excluded ? Array(apt_excluded).dup : nil
      ]
      cached = @excluded_models_cache
      return cached[1] if cached && cached[0] == cache_key

      set = TenantAdapters.resolve(configuration).excluded_models.to_set.freeze
      @excluded_models_cache = [cache_key, set]
      set
    end

    def custom_connection_model?(klass)
      if klass.respond_to?(:connection_class_for_self)
        conn_class = klass.connection_class_for_self
        return true unless primary_connection_class?(conn_class)
      end

      return false unless klass.respond_to?(:connection_handler)

      handler = klass.connection_handler
      klass.ancestors.any? do |ancestor|
        next false unless ancestor.is_a?(Class) && ancestor < ActiveRecord::Base && ancestor.name
        next false if primary_connection_class?(ancestor)

        !handler.retrieve_connection_pool(ancestor.name, strict: false).nil?
      end
    end

    def primary_connection_class?(klass)
      return true if klass == ActiveRecord::Base
      return true if klass.respond_to?(:primary_class?) && klass.primary_class?
      return true if defined?(ApplicationRecord) && klass == ApplicationRecord

      false
    end
  end
end
