# frozen_string_literal: true

module SchemaShard
  module QueryLogger
    class << self
      def install!(logger: nil)
        return @subscriber if @subscriber
        return nil unless defined?(ActiveSupport::Notifications)

        @subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          shard = SchemaShard.current_shard_label
          next unless shard

          log = logger || SchemaShard.configuration.effective_logger
          next unless log

          tenant = SchemaShard.current_tenant
          tag = tenant ? "Shard: #{shard} | Tenant: #{tenant}" : "Shard: #{shard}"
          log.info("\e[33m==[#{tag}] #{payload[:name]} -> #{payload[:sql]}\e[0m")
        end
      end

      def uninstall!
        return unless @subscriber && defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.unsubscribe(@subscriber)
        @subscriber = nil
      end
    end
  end
end
