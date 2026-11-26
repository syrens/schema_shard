# frozen_string_literal: true

module SchemaShard
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvalidTenantError < ArgumentError; end
  class TaintedConnectionError < Error; end
  class PoolLimitExceededError < Error; end
end
