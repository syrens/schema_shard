# frozen_string_literal: true

require 'rails/railtie'

module SchemaShard
  class Railtie < ::Rails::Railtie
    initializer 'schema_shard.active_record' do
      ActiveSupport.on_load(:active_record) do
        SchemaShard.install!
      end
    end

    initializer 'schema_shard.query_logger' do
      config.after_initialize do
        SchemaShard::QueryLogger.install! if SchemaShard.configuration.log_shard_queries
      end
    end

    initializer 'schema_shard.fork_safety' do
      SchemaShard.install_fork_hook! if SchemaShard.configuration.auto_fork_safety
    end

    initializer 'schema_shard.executor' do |app|
      if app.respond_to?(:executor) && app.executor.respond_to?(:to_complete)
        app.executor.to_complete do
          SchemaShard.clear_thread_locals! if SchemaShard.current_shard_label
        end
      end
    end
  end
end
