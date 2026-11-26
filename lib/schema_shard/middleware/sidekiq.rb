# frozen_string_literal: true

module SchemaShard
  module Middleware
    # Sidekiq server middleware guaranteeing SchemaShard execution state is cleared
    # after every job, preventing leaked shard/tenant context across recycled worker threads.
    class Sidekiq
      def call(_worker, _job, _queue)
        yield
      ensure
        SchemaShard.clear_thread_locals!
      end
    end
  end
end
