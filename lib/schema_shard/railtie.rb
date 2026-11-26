# frozen_string_literal: true

require 'rails/railtie'

module SchemaShard
  class Railtie < ::Rails::Railtie
    initializer 'schema_shard.active_record' do
      ActiveSupport.on_load(:active_record) do
        SchemaShard.install!
      end
    end

    initializer 'schema_shard.after_initialize' do
      config.after_initialize do
        SchemaShard::QueryLogger.install! if SchemaShard.configuration.log_shard_queries
        SchemaShard.install_fork_hook! if SchemaShard.configuration.auto_fork_safety
      end
    end

    initializer 'schema_shard.executor' do |app|
      if app.respond_to?(:executor) && app.executor.respond_to?(:to_complete)
        app.executor.to_complete do
          if !SchemaShard::ExecutionContext.in_active_block? && SchemaShard.current_shard_label
            SchemaShard.clear_thread_locals!
          end
        end
      end
    end
  end
end
