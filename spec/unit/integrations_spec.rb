# frozen_string_literal: true

require 'spec_helper'

unless defined?(PG::PQTRANS_IDLE)
  module PG
    PQTRANS_IDLE    = 0
    PQTRANS_INERROR = 3
  end
end

RSpec.describe 'SchemaShard sanitizer, QueryLogger, executor, and stateful Apartment specs' do
  describe 'ConnectionSanitizer#verify_nested_clean! taint marking on discard error' do
    it 'marks enclosing pool frames tainted even when conn.disconnect! raises inside discard_tainted' do
      metrics   = SchemaShard::Metrics.new
      sanitizer = SchemaShard::ConnectionSanitizer.new(configuration: SchemaShard.configuration, metrics: metrics)
      pool      = double('Pool', remove: nil)
      raw       = double('PGConn', transaction_status: PG::PQTRANS_INERROR)
      conn      = double('Conn', raw_connection: raw, discard!: nil)
      allow(conn).to receive(:disconnect!).and_raise(StandardError, 'socket already closed')

      outer_frame = SchemaShard::ExecutionContext.push_pool_frame(pool, tenant: 'tenant_a', tenant_switched: true)

      expect do
        sanitizer.verify_nested_clean!(
          pool, conn,
          shard_key: 's1',
          db_adapter: SchemaShard::DatabaseAdapters::Postgresql.instance,
          tenant_adapter: SchemaShard::TenantAdapters::Native.new(SchemaShard.configuration),
          shard_config: {},
          outer_tenant: 'tenant_a',
          tenant_switched: true
        )
      end.to raise_error(SchemaShard::TaintedConnectionError)

      expect(outer_frame[:tainted]).to be(true)
    ensure
      SchemaShard::ExecutionContext.pop_pool_frame(pool)
    end
  end

  describe SchemaShard::QueryLogger do
    it 'logs only queries executed on active_connection at :debug and respects colorize_logging' do
      messages = []
      logger   = double('Logger')
      allow(logger).to receive(:debug) { |msg| messages << msg }

      shard_conn   = double('ShardConn')
      primary_conn = double('PrimaryConn')

      SchemaShard::QueryLogger.install!(logger: logger)
      ActiveSupport::LogSubscriber.colorize_logging = false

      SchemaShard::ExecutionContext.with_context(shard_key: 'shard01', config: {}, tenant: 'acme', read_only: true) do
        SchemaShard::ExecutionContext.with_connection(shard_conn, double('Pool')) do
          ActiveSupport::Notifications.instrument('sql.active_record',
                                                  name: 'Account Load', sql: 'SELECT * FROM accounts',
                                                  connection: primary_conn)
          ActiveSupport::Notifications.instrument('sql.active_record',
                                                  name: 'Order Load', sql: 'SELECT * FROM orders',
                                                  connection: shard_conn)
        end
      end

      expect(messages.size).to eq(1)
      expect(messages.first).to eq('==[Shard: shard01 | Tenant: acme] Order Load -> SELECT * FROM orders')
    end
  end

  describe 'ExecutionContext depth guard for Rails executor.to_complete' do
    it 'preserves active shard context during nested ActiveSupport::Executor.wrap and clears leaked state outside' do
      executor = Class.new(ActiveSupport::Executor)
      executor.to_complete do
        if !SchemaShard::ExecutionContext.in_active_block? && SchemaShard.current_shard_label
          SchemaShard.clear_thread_locals!
        end
      end

      SchemaShard::ExecutionContext.with_context(shard_key: 's1', config: {}, tenant: 't1', read_only: true) do
        executor.wrap { expect(SchemaShard.current_shard_label).to eq('s1') }
        expect(SchemaShard.current_shard_label).to eq('s1')
      end

      # Simulate leaked state outside an active block
      ActiveSupport::IsolatedExecutionState[SchemaShard::ExecutionContext::LABEL_KEY] = 'leaked_shard'
      executor.wrap { expect(SchemaShard.current_shard_label).to eq('leaked_shard') }
      expect(SchemaShard.current_shard_label).to be_nil
    end

    it 'respects config.auto_fork_safety = false and config.log_shard_queries = true on boot' do
      SchemaShard.configuration.auto_fork_safety  = false
      SchemaShard.configuration.log_shard_queries = true

      expect(SchemaShard).not_to receive(:install_fork_hook!)
      expect(SchemaShard::QueryLogger).to receive(:install!).once

      SchemaShard::QueryLogger.install! if SchemaShard.configuration.log_shard_queries
      SchemaShard.install_fork_hook! if SchemaShard.configuration.auto_fork_safety
    end
  end

  describe 'cached_excluded_models_set in-place mutation and tenant_mode toggle' do
    it 'invalidates cache immediately on in-place excluded_models << and tenant_mode changes' do
      billing_klass = Class.new(ActiveRecord::Base)
      stub_const('Billing', billing_klass)

      expect(SchemaShard.routable_model?(Billing)).to be(true)

      SchemaShard.configuration.excluded_models << 'Billing'
      expect(SchemaShard.routable_model?(Billing)).to be(false)

      SchemaShard.configuration.excluded_models.clear
      stub_const('::Apartment', Module.new do
        def self.excluded_models = ['Billing']
      end)
      stub_const('::Apartment::Tenant', Module.new)
      SchemaShard.configuration.tenant_adapter = :auto
      SchemaShard.configuration.tenant_mode    = :strict
      expect(SchemaShard.routable_model?(Billing)).to be(false)

      SchemaShard.configuration.tenant_mode = :none
      expect(SchemaShard.routable_model?(Billing)).to be(true)
    end
  end

  describe 'Stateful TenantAdapters::Apartment integration' do
    it 'switches tenants and restores pre-existing request tenant cleanly' do
      stateful_tenant = Module.new do
        @current = 'request_tenant'
        class << self
          attr_accessor :current

          def switch(tenant)
            prev = @current
            @current = tenant
            yield
          ensure
            @current = prev
          end
        end
      end

      stub_const('::Apartment', Module.new do
        def self.default_schema = 'public'
        def self.persistent_schemas = []
        def self.excluded_models = ['Account']
      end)
      stub_const('::Apartment::Tenant', stateful_tenant)

      raw_pg = double('PG::Connection', transaction_status: PG::PQTRANS_IDLE)
      fake_conn = double(
        'PGAdapter',
        raw_connection: raw_pg,
        schema_search_path: '"public"',
        clear_query_cache: nil,
        clear_cache!: nil,
        select_value: '"public"'
      )
      allow(fake_conn).to receive(:schema_search_path=) do |val|
        allow(fake_conn).to receive(:schema_search_path).and_return(val)
      end

      fake_pool = double('Pool', stat: { size: 5, busy: 0 }, clear_query_cache: nil, disconnect!: nil)
      allow(fake_pool).to receive(:with_connection) { |&blk| blk.call(fake_conn) }

      SchemaShard.configure do |c|
        c.env            = 'test'
        c.default_shard  = 'shard01'
        c.tenant_adapter = :auto
        c.shards         = { 'test' => { 'shard01' => { 'adapter' => 'postgresql', 'host' => 'db', 'database' => 'app' } } }
      end
      allow(SchemaShard.pool_registry).to receive(:build_connection_pool).and_return(fake_pool)

      observed = nil
      SchemaShard.with('target_tenant') do
        observed = Apartment::Tenant.current
      end

      expect(observed).to eq('target_tenant')
      expect(Apartment::Tenant.current).to eq('request_tenant')
    end
  end

  describe 'Metrics max_tracked_shards cardinality cap' do
    it 'buckets overflow shard keys into _other once max_tracked_shards is reached' do
      SchemaShard.configuration.max_tracked_shards = 2
      metrics = SchemaShard::Metrics.new(configuration: SchemaShard.configuration)

      metrics.track_switch('shard_1')
      metrics.track_switch('shard_2')
      metrics.track_switch('shard_3')
      metrics.track_switch('shard_4')

      per_shard = metrics.snapshot(pool_status: {})[:per_shard]
      expect(per_shard.keys).to contain_exactly('shard_1', 'shard_2', '_other')
      expect(per_shard['_other'][:switches_total]).to eq(2)
    end
  end

  describe 'Fiber concurrency isolation (isolation_level = :fiber)' do
    it 'isolates ExecutionContext between interleaved Fibers on the same Thread' do
      prev_level = ActiveSupport::IsolatedExecutionState.isolation_level
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber

      observed = []
      f1 = Fiber.new do
        SchemaShard::ExecutionContext.with_context(shard_key: 's1', config: {}, tenant: 'tenant_a', read_only: true) do
          observed << [:f1_before, SchemaShard.current_tenant]
          Fiber.yield
          observed << [:f1_after, SchemaShard.current_tenant]
        end
      end

      f2 = Fiber.new do
        SchemaShard::ExecutionContext.with_context(shard_key: 's1', config: {}, tenant: 'tenant_b', read_only: true) do
          observed << [:f2_before, SchemaShard.current_tenant]
          Fiber.yield
          observed << [:f2_after, SchemaShard.current_tenant]
        end
      end

      f1.resume
      f2.resume
      f1.resume
      f2.resume

      expect(observed).to eq([
                               [:f1_before, 'tenant_a'],
                               [:f2_before, 'tenant_b'],
                               [:f1_after, 'tenant_a'],
                               [:f2_after, 'tenant_b']
                             ])
    ensure
      ActiveSupport::IsolatedExecutionState.isolation_level = prev_level
    end
  end

  describe 'Install generator templates' do
    let(:templates_dir) { File.expand_path('../../lib/generators/schema_shard/templates', __dir__) }

    it 'renders valid Ruby in initializer.rb.tt' do
      source = File.read(File.join(templates_dir, 'initializer.rb.tt'))
      expect { RubyVM::InstructionSequence.compile(source) }.not_to raise_error
    end

    it 'renders valid ERB/YAML in shards.yml.tt parseable by ConfigLoader for dev, test, and prod' do
      path = File.join(templates_dir, 'shards.yml.tt')
      cfg  = SchemaShard::Configuration.new
      cfg.config_path = path

      %w[development test].each do |env_name|
        cfg.env = env_name
        shard = SchemaShard::ConfigLoader.new(configuration: cfg).fetch!('shard01')
        expect(shard['adapter']).to eq('postgresql')
        expect(shard['host']).to eq('localhost')
      end

      prev_url = ENV.fetch('SHARD01_DATABASE_URL', nil)
      ENV['SHARD01_DATABASE_URL'] = 'trilogy://ro:pass@mysql.internal:3306/app_prod'
      cfg.env = 'production'
      prod_shard = SchemaShard::ConfigLoader.new(configuration: cfg).fetch!('shard01')
      expect(prod_shard['adapter']).to eq('trilogy')
      expect(prod_shard['host']).to eq('mysql.internal')
      expect(prod_shard['database']).to eq('app_prod')
    ensure
      ENV['SHARD01_DATABASE_URL'] = prev_url
    end
  end
end
