# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module DatabaseAdapters
    class Generic < Base
      def validate_config!(shard_key, shard_cfg)
        has_url = present_value?(shard_cfg['url'] || shard_cfg[:url])
        has_db  = present_value?(shard_cfg['database'] || shard_cfg[:database])
        return if has_url || has_db

        raise ArgumentError, "Shard '#{shard_key}' must explicitly configure 'database' or 'url'"
      end
    end
  end
end
