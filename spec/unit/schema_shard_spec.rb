# frozen_string_literal: true

require 'spec_helper'

unless defined?(PG::PQTRANS_IDLE)
  module PG
    PQTRANS_IDLE    = 0
    PQTRANS_INERROR = 3
  end
end

RSpec.describe SchemaShard do
  let(:raw_pg_conn) { double('PG::Connection', transaction_status: PG::PQTRANS_IDLE) }
  let(:fake_conn) do
    double(
      'ActiveRecord::ConnectionAdapters::PostgreSQLAdapter',
      raw_connection: raw_pg_conn,
      schema_search_path: '"public"',
      clear_query_cache: nil,
      clear_cache!: nil,
      discard!: nil,
      disconnect!: nil,
      select_value: '"public"'
    ).tap do |c|
      allow(c).to receive(:schema_search_path=) { |val| allow(c).to receive(:schema_search_path).and_return(val) }
    end
  end

  let(:fake_pool) do
    double(
      'ActiveRecord::ConnectionAdapters::ConnectionPool',
      stat: { size: 5, busy: 0, dead: 0, idle: 5, waiting: 0, checkout_timeout: 5 },
      size: 5,
      checkout_timeout: 5,
      clear_query_cache: nil,
      remove: nil,
      disconnect!: nil,
      discard!: nil
    ).tap do |p|
      allow(p).to receive(:with_connection) { |&blk| blk.call(fake_conn) }
      allow(p).to receive(:db_config).and_return(
        double(configuration_hash: { pool: 5, checkout_timeout: 5 })
      )
    end
  end

  let(:shard_configs) do
    {
      'test' => {
        'shard01' => {
          'adapter' => 'postgresql',
          'host' => 'replica-1.internal',
          'port' => 5432,
          'database' => 'app_production',
          'username' => 'readonly_user'
        },
        'shard02' => {
          'adapter' => 'postgresql',
          'host' => 'replica-2.internal',
          'port' => 5432,
          'database' => 'app_production',
          'username' => 'readonly_user'
        }
      }
    }
  end

  before do
    described_class.configure do |config|
      config.env            = 'test'
      config.default_shard  = 'shard01'
      config.shards         = shard_configs
      config.tenant_adapter = :native
      config.tenant_mode    = :strict
    end

    allow(described_class.pool_registry).to receive(:build_connection_pool).and_return(fake_pool)
  end

  describe 'tenant validation and tenant modes' do
    it 'rejects nil, empty, whitespace, system, and malformed tenant names in :strict mode' do
      [nil, '', '   ', 'pg_catalog', 'pg_toast', 'information_schema',
       'tenant_a, public', 'tenant_a; DROP TABLE users', '123bad', 'a' * 64].each do |bad_tenant|
        expect do
          described_class.with(bad_tenant) { :never_runs }
        end.to raise_error(SchemaShard::InvalidTenantError)
      end
    end

    it 'rejects public schema in :strict mode unless explicitly opted in' do
      expect do
        described_class.with('public') { :never_runs }
      end.to raise_error(SchemaShard::InvalidTenantError)

      expect(described_class.with_public { described_class.current_tenant }).to eq('public')
      expect(described_class.with('public', allow_public: true) { described_class.current_tenant }).to eq('public')
    end

    it 'accepts valid tenant names including hyphens' do
      result = described_class.with('my-tenant_01') { described_class.current_tenant }
      expect(result).to eq('my-tenant_01')
    end

    it 'allows nil tenant and falls back to shard default in :optional mode' do
      described_class.configuration.tenant_mode = :optional

      result = described_class.with(nil, shard_key: 'shard01') do
        [described_class.current_shard_label, described_class.current_tenant]
      end

      expect(result).to eq(['shard01', nil])
    end

    it 'skips tenant switching completely in :none mode' do
      described_class.configuration.tenant_mode = :none

      result = described_class.with('ignored_tenant', shard_key: 'shard01') do
        [described_class.current_shard_label, described_class.current_tenant]
      end

      expect(result).to eq(['shard01', nil])
    end

    it 'supports explicit shard-only routing via .on_shard even in :strict mode' do
      result = described_class.on_shard('shard02') do
        [described_class.current_shard_label, described_class.current_tenant, described_class.active_connection]
      end

      expect(result).to eq(['shard02', nil, fake_conn])
    end
  end

  describe 'model routing isolation (ConnectionPatch)' do
    it 'routes normal tenant models to the shard connection' do
      expect(described_class.routable_model?(ActiveRecord::Base)).to be(true)
    end

    it 'does NOT hijack configured excluded_models' do
      excluded_klass = Class.new(ActiveRecord::Base)
      stub_const('Account', excluded_klass)
      described_class.configuration.excluded_models = %w[Account]

      expect(described_class.routable_model?(Account)).to be(false)
    end

    it 'does NOT hijack models inheriting from a connects_to / custom connection abstract class' do
      custom_abstract = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
        def self.connection_class_for_self
          self
        end
      end
      concrete_subclass = Class.new(custom_abstract) do
        def self.connection_class_for_self
          superclass
        end
      end

      expect(described_class.routable_model?(custom_abstract)).to be(false)
      expect(described_class.routable_model?(concrete_subclass)).to be(false)
    end
  end

  describe 'TenantAdapters.resolve (:auto)' do
    it 'auto-detects top-level ::Apartment::Tenant when loaded' do
      described_class.configuration.tenant_adapter = :auto
      expect(SchemaShard::TenantAdapters.resolve(described_class.configuration))
        .to be_a(SchemaShard::TenantAdapters::Native)

      stub_const('::Apartment::Tenant', Module.new)
      expect(SchemaShard::TenantAdapters.resolve(described_class.configuration))
        .to be_a(SchemaShard::TenantAdapters::Apartment)
    end
  end

  describe 'nested execution, query cache hygiene, and fail-closed sanitization' do
    it 'clears query cache on entry and exit of nested same-shard different-tenant switches' do
      expect(fake_conn).to receive(:clear_query_cache).at_least(4).times

      described_class.with('tenant_a', shard_key: 'shard01') do
        expect(described_class.current_tenant).to eq('tenant_a')
        expect(fake_conn.schema_search_path).to eq('"tenant_a"')

        described_class.with('tenant_b', shard_key: 'shard01') do
          expect(described_class.current_tenant).to eq('tenant_b')
          expect(fake_conn.schema_search_path).to eq('"tenant_b"')
        end

        expect(described_class.current_tenant).to eq('tenant_a')
        expect(fake_conn.schema_search_path).to eq('"tenant_a"')
      end

      expect(described_class.current_tenant).to be_nil
      expect(described_class.active_connection).to be_nil
      expect(fake_conn.schema_search_path).to eq('"public"')
    end

    it 'discards connection on non-idle PostgreSQL transaction (fail closed)' do
      allow(raw_pg_conn).to receive(:transaction_status).and_return(PG::PQTRANS_INERROR)
      expect(fake_conn).to receive(:discard!)
      expect(fake_pool).to receive(:remove).with(fake_conn)
      expect(fake_conn).to receive(:disconnect!)

      described_class.with('tenant_a') { :ok }
    end

    it 'discards connection when raw_connection is nil (fail closed)' do
      allow(fake_conn).to receive(:raw_connection).and_return(nil)
      expect(fake_pool).to receive(:remove).with(fake_conn)
      expect(fake_conn).to receive(:disconnect!)

      described_class.with('tenant_a') { :ok }
    end
  end

  describe 'read-only enforcement' do
    it 'wraps execution in ActiveRecord::Base.while_preventing_writes by default' do
      expect(ActiveRecord::Base).to receive(:while_preventing_writes).and_yield
      described_class.with('tenant_a') { :ok }
    end

    it 'injects default_transaction_read_only=on into Rails 8 HashConfig/PoolConfig' do
      allow(described_class.pool_registry).to receive(:build_connection_pool).and_call_original

      captured_pool_config = nil
      allow(ActiveRecord::ConnectionAdapters::ConnectionPool).to receive(:new) do |pool_config|
        captured_pool_config = pool_config
        fake_pool
      end

      described_class.with('tenant_a', shard_key: 'shard01') { :ok }

      expect(captured_pool_config).to be_a(ActiveRecord::ConnectionAdapters::PoolConfig)
      expect(captured_pool_config.role).to eq(:reading)
      vars = captured_pool_config.db_config.configuration_hash[:variables]
      expect(vars['default_transaction_read_only']).to eq('on')
    end
    it 'refuses to escalate from read_only: true to read_only: false in a nested block' do
      expect do
        described_class.with('tenant_a', read_only: true) do
          described_class.with('tenant_a', read_only: false) { :never }
        end
      end.to raise_error(SchemaShard::ConfigurationError)
    end
  end

  describe 'pool registry, eviction concurrency, and fork safety' do
    it 'produces distinct opaque pool keys when database, username, password, or variables differ' do
      cfg_a = { 'host' => 'db1', 'database' => 'app_tenant_1', 'username' => 'ro1', 'password' => 'secret_a' }
      cfg_b = { 'host' => 'db1', 'database' => 'app_tenant_2', 'username' => 'ro1', 'password' => 'secret_a' }
      cfg_c = { 'host' => 'db1', 'database' => 'app_tenant_1', 'username' => 'ro2', 'password' => 'secret_a' }
      cfg_d = { 'host' => 'db1', 'database' => 'app_tenant_1', 'username' => 'ro1', 'password' => 'secret_b' }

      key_a = described_class.pool_registry.build_pool_key(cfg_a, 'shard01', read_only: true)
      key_b = described_class.pool_registry.build_pool_key(cfg_b, 'shard01', read_only: true)
      key_c = described_class.pool_registry.build_pool_key(cfg_c, 'shard01', read_only: true)
      key_d = described_class.pool_registry.build_pool_key(cfg_d, 'shard01', read_only: true)

      expect([key_a, key_b, key_c, key_d].uniq.size).to eq(4)
      expect(key_a).not_to include('db1')
      expect(key_a).not_to include('secret_a')
    end

    it 'never evicts a pool while concurrent threads are actively using it' do
      errors = Queue.new
      stop   = Concurrent::AtomicBoolean.new(false)

      cleaner = Thread.new do
        until stop.true?
          described_class.cleanup_unused_pools!
          Thread.pass
        end
      end

      workers = Array.new(8) do |i|
        Thread.new do
          20.times do
            described_class.with("tenant_#{i}", shard_key: 'shard01') do
              raise 'missing active conn' if described_class.active_connection.nil?
            end
          end
        rescue StandardError => e
          errors << e
        end
      end

      workers.each(&:join)
      stop.make_true
      cleaner.join

      expect(errors).to be_empty
    end

    it 'discards inherited pools after fork via ConnectionPool#discard! without calling disconnect!' do
      described_class.with('tenant_a') { :ok }
      expect(described_class.pool_count).to eq(1)
      expect(fake_pool).to receive(:discard!)
      expect(fake_pool).not_to receive(:disconnect!)

      described_class.discard_pools_after_fork!
      expect(described_class.pool_count).to eq(0)
    end
  end

  describe 'observability formats' do
    it 'emits StatsD cumulative counters as gauges and omits Prometheus timestamps' do
      described_class.with('tenant_a') { :ok }

      statsd = described_class.statsd_metrics
      expect(statsd.all? { |m| m[:type] == :gauge }).to be(true)

      prom = described_class.prometheus_metrics
      sample_lines = prom.lines.reject { |l| l.start_with?('#') }
      expect(sample_lines).to all(match(/\A\S+ \d+(\.\d+)?\n\z/))
    end
  end

  describe 'Middleware::Sidekiq' do
    it 'clears shard execution context even when the job raises' do
      middleware = SchemaShard::Middleware::Sidekiq.new
      ActiveSupport::IsolatedExecutionState[SchemaShard::ExecutionContext::LABEL_KEY] = 'shard01'

      expect do
        middleware.call(nil, {}, 'default') { raise 'boom' }
      end.to raise_error('boom')

      expect(SchemaShard.current_shard_label).to be_nil
    end
  end
end
