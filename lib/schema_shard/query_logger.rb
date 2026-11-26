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

          active_conn = SchemaShard.active_connection
          next if payload.key?(:connection) && active_conn && !payload[:connection].equal?(active_conn)

          log = logger || SchemaShard.configuration.effective_logger
          next unless log

          tenant = SchemaShard.current_tenant
          tag = tenant ? "Shard: #{shard} | Tenant: #{tenant}" : "Shard: #{shard}"
          message = format_message(tag, payload[:name], payload[:sql])
          log.debug(message)
        end
      end

      def uninstall!
        return unless @subscriber && defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.unsubscribe(@subscriber)
        @subscriber = nil
      end

      private

      def format_message(tag, name, sql)
        line = "==[#{tag}] #{name} -> #{sql}"
        return "\e[33m#{line}\e[0m" if colorize?

        line
      end

      def colorize?
        defined?(ActiveSupport::LogSubscriber) && ActiveSupport::LogSubscriber.colorize_logging
      end
    end
  end
end
