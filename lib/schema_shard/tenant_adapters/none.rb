# frozen_string_literal: true

require_relative 'base'

module SchemaShard
  module TenantAdapters
    # No-op tenant adapter for pure database sharding / read-replica routing.
    class None < Base
      def switches_tenant?
        false
      end
    end
  end
end
