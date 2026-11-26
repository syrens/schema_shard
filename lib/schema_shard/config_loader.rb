# frozen_string_literal: true

require 'erb'
require 'yaml'

module SchemaShard
  class ConfigLoader
    def initialize(configuration:)
      @configuration = configuration
      @mutex = Mutex.new
      @cache = nil
    end

    def fetch!(shard_key)
      config = load_all
      env_name = @configuration.effective_env
      env_config = config[env_name] || config[env_name.to_sym]

      raise ArgumentError, "Environment '#{env_name}' not found in shard configuration" unless env_config.is_a?(Hash)

      shard_cfg = env_config[shard_key.to_s] || env_config[shard_key.to_sym]
      unless shard_cfg.is_a?(Hash)
        raise ArgumentError, "Shard '#{shard_key}' not found in shard configuration for environment '#{env_name}'"
      end

      db_adapter = DatabaseAdapters.for(shard_cfg['adapter'] || shard_cfg[:adapter])
      db_adapter.validate_config!(shard_key, shard_cfg)
      shard_cfg
    end

    def reload!
      @mutex.synchronize { @cache = nil }
      nil
    end

    def load_all
      cached = @cache
      return cached if cached

      @mutex.synchronize do
        @cache ||= deep_freeze(load_and_parse)
      end
    end

    private

    def load_and_parse
      if @configuration.shards
        raw = @configuration.shards.respond_to?(:call) ? @configuration.shards.call : @configuration.shards
        raise ArgumentError, 'Configured shards must be a Hash' unless raw.is_a?(Hash)

        return extract_root(stringify_nested_keys(raw))
      end

      load_from_yaml
    end

    def load_from_yaml
      path = @configuration.config_path
      content = begin
        File.read(path)
      rescue Errno::ENOENT
        raise ArgumentError, "shards.yml not found at #{path}"
      end

      rendered = begin
        ERB.new(content).result
      rescue StandardError => e
        raise ArgumentError, "shards.yml ERB evaluation failed: #{e.message}"
      end

      parsed = begin
        YAML.safe_load(rendered, aliases: true)
      rescue Psych::SyntaxError => e
        raise ArgumentError, "shards.yml is malformed: #{e.message}"
      end

      raise ArgumentError, 'shards.yml must parse to a YAML mapping' unless parsed.is_a?(Hash)

      extract_root(parsed)
    end

    def extract_root(parsed)
      root_key = @configuration.config_root_key
      return parsed if root_key.nil? || root_key.to_s.empty?

      shards = parsed.fetch(root_key.to_s) do
        raise ArgumentError, "shards.yml is missing required top-level '#{root_key}' key"
      end

      raise ArgumentError, "shards.yml '#{root_key}' entry must be a YAML mapping" unless shards.is_a?(Hash)

      shards
    end

    def stringify_nested_keys(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify_nested_keys(v) }
      when Array
        obj.map { |v| stringify_nested_keys(v) }
      else
        obj
      end
    end

    def deep_freeze(obj)
      case obj
      when Hash
        obj.each do |k, v|
          deep_freeze(k)
          deep_freeze(v)
        end
      when Array
        obj.each { |v| deep_freeze(v) }
      end
      obj.freeze
    end
  end
end
