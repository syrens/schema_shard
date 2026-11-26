# frozen_string_literal: true

module SchemaShard
  class Configuration
    VALID_TENANT_MODES = %i[strict optional none].freeze

    attr_accessor :config_root_key, :shards, :default_shard,
                  :tenant_adapter, :default_schema, :persistent_schemas,
                  :excluded_models, :default_pool_size, :checkout_timeout,
                  :reaping_frequency, :logger, :env, :log_shard_queries,
                  :auto_fork_safety, :live_verify_fast_path, :max_tracked_shards
    attr_writer :config_path
    attr_reader :tenant_mode, :max_pools, :cleanup_threshold

    def initialize
      @config_path        = nil
      @config_root_key    = nil
      @shards             = nil
      @default_shard      = nil
      @tenant_adapter     = :auto
      @tenant_mode        = :strict
      @default_schema     = 'public'
      @persistent_schemas = []
      @excluded_models    = []
      @max_pools          = [ENV.fetch('SCHEMA_SHARD_MAX_POOLS', 10).to_i, 1].max
      @cleanup_threshold  = clamp_cleanup_threshold(ENV.fetch('SCHEMA_SHARD_CLEANUP_THRESHOLD', 8).to_i)
      @default_pool_size  = [ENV.fetch('RAILS_MAX_THREADS', 5).to_i, 1].max
      @checkout_timeout   = 5
      @reaping_frequency  = 10
      @logger             = nil
      @env                = nil
      @log_shard_queries     = false
      @auto_fork_safety      = true
      @live_verify_fast_path = false
      @max_tracked_shards    = 100
    end

    def config_path
      @config_path || default_config_path
    end

    def tenant_mode=(mode)
      sym = mode.to_sym
      unless VALID_TENANT_MODES.include?(sym)
        raise ConfigurationError,
              "Invalid tenant_mode: #{mode.inspect}. Expected one of #{VALID_TENANT_MODES.inspect}"
      end

      @tenant_mode = sym
    end

    def max_pools=(value)
      @max_pools = [value.to_i, 1].max
      @cleanup_threshold = clamp_cleanup_threshold(@cleanup_threshold)
    end

    def cleanup_threshold=(value)
      @cleanup_threshold = clamp_cleanup_threshold(value.to_i)
    end

    def effective_env
      return @env.to_s unless @env.nil? || @env.to_s.empty?

      default_env
    end

    def effective_logger
      return @logger unless @logger.nil?

      default_logger
    end

    private

    def clamp_cleanup_threshold(value)
      value.clamp(1, @max_pools)
    end

    def default_config_path
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join('config', 'shards.yml')
      else
        File.join('config', 'shards.yml')
      end
    end

    def default_logger
      Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
    end

    def default_env
      if defined?(Rails) && Rails.respond_to?(:env) && Rails.env
        Rails.env.to_s
      else
        ENV.fetch('RAILS_ENV', ENV.fetch('RACK_ENV', 'development'))
      end
    end
  end
end
