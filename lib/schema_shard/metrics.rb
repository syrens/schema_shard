# frozen_string_literal: true

require 'concurrent'

module SchemaShard
  class Metrics
    METRIC_KEYS = %i[
      pools_created_total
      pools_evicted_total
      pools_cleanup_total
      connection_checkouts_total
      connection_verification_failures_total
      connection_timeouts_total
      connection_discards_total
      shard_switches_total
    ].freeze

    SHARD_METRIC_KEYS = %i[
      pools_created_total
      verification_failures_total
      switches_total
      connection_discards_total
    ].freeze

    def initialize
      @metrics       = Concurrent::Map.new
      @shard_metrics = Concurrent::Map.new
      METRIC_KEYS.each { |k| @metrics[k] = Concurrent::AtomicFixnum.new(0) }
    end

    def increment(metric_name, count = 1)
      key = metric_name.to_sym
      return unless METRIC_KEYS.include?(key)

      counter = @metrics.compute_if_absent(key) { Concurrent::AtomicFixnum.new(0) }
      counter.increment(count)
    end

    def increment_shard(shard_key, metric_name, count = 1)
      key = metric_name.to_sym
      return unless SHARD_METRIC_KEYS.include?(key)

      shard_str = shard_key.to_s
      shard_map = @shard_metrics.compute_if_absent(shard_str) { Concurrent::Map.new }
      counter   = shard_map.compute_if_absent(key) { Concurrent::AtomicFixnum.new(0) }
      counter.increment(count)
    end

    def track_switch(shard_key)
      increment(:shard_switches_total)
      increment_shard(shard_key, :switches_total)
    end

    def snapshot(pool_status:)
      global_snapshot = {}
      @metrics.each_pair { |k, counter| global_snapshot[k] = counter.value }

      per_shard_snapshot = {}
      @shard_metrics.each_pair do |shard, metric_map|
        shard_hash = {}
        metric_map.each_pair { |name, counter| shard_hash[name] = counter.value }
        per_shard_snapshot[shard] = shard_hash
      end

      {
        global: global_snapshot,
        per_shard: per_shard_snapshot,
        timestamp: Time.now.to_f,
        pools: pool_status
      }
    end

    def prometheus(pool_status:)
      current = snapshot(pool_status: pool_status)
      lines   = []

      append_global_prometheus_lines(lines, current[:global])
      append_pool_prometheus_lines(lines, current[:pools])
      append_per_shard_prometheus_lines(lines, current[:per_shard])

      "#{lines.join("\n")}\n"
    end

    def statsd(pool_status:)
      current = snapshot(pool_status: pool_status)
      output  = current[:global].map do |name, value|
        { name: "schema_shard.#{name}", value: value, type: :gauge, tags: ['component:schema_shard'] }
      end

      pm = current[:pools]
      output << { name: 'schema_shard.pools.active_count',
                  value: pm[:active_count], type: :gauge,
                  tags: ['component:schema_shard'] }
      output << { name: 'schema_shard.pools.usage_percentage',
                  value: pm[:usage_percentage], type: :gauge,
                  tags: ['component:schema_shard'] }

      current[:per_shard].each do |shard, data|
        data.each do |name, value|
          output << { name: "schema_shard.shard.#{name}", value: value,
                      type: :gauge,
                      tags: ['component:schema_shard', "shard:#{shard}"] }
        end
      end

      output
    end

    def reset!
      @metrics.each_value { |counter| counter.value = 0 }
      @shard_metrics.clear
    end

    private

    def append_global_prometheus_lines(lines, global_metrics)
      global_metrics.each do |name, value|
        lines << "# HELP schema_shard_#{name} #{name.to_s.tr('_', ' ').capitalize}"
        lines << "# TYPE schema_shard_#{name} counter"
        lines << "schema_shard_#{name} #{value}"
      end
    end

    def append_pool_prometheus_lines(lines, pool_metrics)
      lines << '# HELP schema_shard_pools_active Number of currently active shard connection pools'
      lines << '# TYPE schema_shard_pools_active gauge'
      lines << "schema_shard_pools_active #{pool_metrics[:active_count]}"
      lines << '# HELP schema_shard_pools_usage_percentage Percentage of maximum allowed shard pools in use'
      lines << '# TYPE schema_shard_pools_usage_percentage gauge'
      lines << "schema_shard_pools_usage_percentage #{pool_metrics[:usage_percentage]}"
    end

    def append_per_shard_prometheus_lines(lines, per_shard_metrics)
      by_metric = Hash.new { |h, k| h[k] = [] }
      per_shard_metrics.each do |shard, data|
        data.each { |name, value| by_metric[name] << [shard, value] }
      end

      by_metric.each do |name, samples|
        metric_id = "schema_shard_per_shard_#{name}"
        lines << "# HELP #{metric_id} Per-shard #{name.to_s.tr('_', ' ')}"
        lines << "# TYPE #{metric_id} counter"
        samples.each do |shard, value|
          lines << "#{metric_id}{shard=\"#{escape_prometheus_label(shard)}\"} #{value}"
        end
      end
    end

    def escape_prometheus_label(value)
      value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')
    end
  end
end
