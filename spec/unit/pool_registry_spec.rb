# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SchemaShard::PoolRegistry do
  let(:configuration) { SchemaShard::Configuration.new }
  let(:metrics) { SchemaShard::Metrics.new }
  let(:registry) { described_class.new(configuration: configuration, metrics: metrics) }
  let(:db_adapter) { SchemaShard::DatabaseAdapters::Postgresql.instance }

  def build_fake_pool(busy: 0)
    double(
      'ActiveRecord::ConnectionAdapters::ConnectionPool',
      stat: { size: 5, busy: busy, dead: 0, idle: 5 - busy, waiting: 0, checkout_timeout: 5 },
      disconnect!: nil,
      discard!: nil
    )
  end

  before do
    configuration.env = 'test'
  end

  it 'evicts the oldest-accessed idle pool first when max_pools is reached' do
    configuration.max_pools         = 2
    configuration.cleanup_threshold = 2

    pool_a = build_fake_pool
    pool_b = build_fake_pool
    pool_c = build_fake_pool
    pools  = [pool_a, pool_b, pool_c]

    allow(registry).to receive(:build_connection_pool) { pools.shift }

    e1 = registry.acquire({ 'host' => 'h1', 'database' => 'd1' }, 's1', db_adapter: db_adapter)
    e1.release
    e2 = registry.acquire({ 'host' => 'h2', 'database' => 'd2' }, 's2', db_adapter: db_adapter)
    e2.release

    expect(pool_a).to receive(:disconnect!).once
    e3 = registry.acquire({ 'host' => 'h3', 'database' => 'd3' }, 's3', db_adapter: db_adapter)
    e3.release

    expect(registry.pool_count).to be <= 2
  end

  it 'raises PoolLimitExceededError when all max_pools are actively in use' do
    configuration.max_pools         = 2
    configuration.cleanup_threshold = 2

    allow(registry).to receive(:build_connection_pool) { build_fake_pool }

    e1 = registry.acquire({ 'host' => 'h1', 'database' => 'd1' }, 's1', db_adapter: db_adapter)
    e2 = registry.acquire({ 'host' => 'h2', 'database' => 'd2' }, 's2', db_adapter: db_adapter)

    expect do
      registry.acquire({ 'host' => 'h3', 'database' => 'd3' }, 's3', db_adapter: db_adapter)
    end.to raise_error(SchemaShard::PoolLimitExceededError)
  ensure
    e1&.release
    e2&.release
  end

  it 'evicts multiple idle pools when max_pools is shrunk at runtime' do
    configuration.max_pools         = 4
    configuration.cleanup_threshold = 4

    p1 = build_fake_pool
    p2 = build_fake_pool
    p3 = build_fake_pool
    p4 = build_fake_pool
    pools = [p1, p2, p3, p4]
    allow(registry).to receive(:build_connection_pool) { pools.shift }

    %w[s1 s2 s3].each do |s|
      entry = registry.acquire({ 'host' => s, 'database' => s }, s, db_adapter: db_adapter)
      entry.release
    end

    configuration.max_pools = 2
    expect(p1).to receive(:disconnect!).once
    expect(p2).to receive(:disconnect!).once

    e4 = registry.acquire({ 'host' => 's4', 'database' => 's4' }, 's4', db_adapter: db_adapter)
    e4.release

    expect(registry.pool_count).to be <= 2
  end

  it 'disconnects already-evicted pools even if build_connection_pool raises' do
    configuration.max_pools         = 1
    configuration.cleanup_threshold = 1

    pool_a = build_fake_pool
    calls  = 0
    allow(registry).to receive(:build_connection_pool) do
      calls += 1
      raise 'boom building pool' if calls == 2

      pool_a
    end

    e1 = registry.acquire({ 'host' => 'h1', 'database' => 'd1' }, 's1', db_adapter: db_adapter)
    e1.release

    expect(pool_a).to receive(:disconnect!).once
    expect do
      registry.acquire({ 'host' => 'h2', 'database' => 'd2' }, 's2', db_adapter: db_adapter)
    end.to raise_error(RuntimeError, 'boom building pool')
  end

  it 'rotates pools cleanly when reload_config! updates shard credentials' do
    SchemaShard.configure do |c|
      c.env            = 'test'
      c.tenant_adapter = :none
      c.shards         = { 'test' => { 's1' => { 'adapter' => 'postgresql', 'host' => 'h1',
                                                 'database' => 'd1', 'password' => 'v1' } } }
    end

    pool_v1 = build_fake_pool
    pool_v2 = build_fake_pool
    allow(pool_v1).to receive(:with_connection).and_yield(
      double('Conn', raw_connection: double(transaction_status: PG::PQTRANS_IDLE),
                     clear_query_cache: nil, clear_cache!: nil)
    )
    allow(pool_v2).to receive(:with_connection).and_yield(
      double('Conn', raw_connection: double(transaction_status: PG::PQTRANS_IDLE),
                     clear_query_cache: nil, clear_cache!: nil)
    )
    pools = [pool_v1, pool_v2]
    allow(SchemaShard.pool_registry).to receive(:build_connection_pool) { pools.shift }

    SchemaShard.on_shard('s1') { :first }
    expect(SchemaShard.pool_count).to eq(1)

    SchemaShard.configuration.shards = {
      'test' => { 's1' => { 'adapter' => 'postgresql', 'host' => 'h1', 'database' => 'd1', 'password' => 'v2' } }
    }
    expect(pool_v1).to receive(:disconnect!).once
    SchemaShard.reload_config!

    SchemaShard.on_shard('s1') { :second }
    expect(SchemaShard.pool_count).to eq(1)
  end
end
