# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SchemaShard::DatabaseAdapters do
  describe '.for' do
    it 'resolves built-in adapters by name' do
      expect(described_class.for('postgresql')).to be_a(SchemaShard::DatabaseAdapters::Postgresql)
      expect(described_class.for('postgis')).to be_a(SchemaShard::DatabaseAdapters::Postgresql)
      expect(described_class.for('mysql2')).to be_a(SchemaShard::DatabaseAdapters::Mysql)
      expect(described_class.for('trilogy')).to be_a(SchemaShard::DatabaseAdapters::Mysql)
      expect(described_class.for('sqlite3')).to be_a(SchemaShard::DatabaseAdapters::Sqlite)
      expect(described_class.for('sqlserver')).to be_a(SchemaShard::DatabaseAdapters::Generic)
    end

    it 'allows registering custom database adapters' do
      custom_class = Class.new(SchemaShard::DatabaseAdapters::Base)
      custom_instance = custom_class.new
      described_class.register('cockroachdb', custom_instance)

      expect(described_class.for('cockroachdb')).to eq(custom_instance)
    end
  end

  describe SchemaShard::DatabaseAdapters::Mysql do
    subject(:adapter) { described_class.instance }

    it 'injects transaction_read_only=1 for read-only pools' do
      cfg = adapter.apply_read_only_config({ 'adapter' => 'trilogy', 'host' => 'db', 'database' => 'app' })
      expect(cfg['variables']['transaction_read_only']).to eq(1)
    end

    it 'rejects forbidden MySQL system databases' do
      %w[mysql information_schema performance_schema sys].each do |sys_db|
        expect do
          adapter.validate_tenant!(sys_db, default_namespace: 'app_main')
        end.to raise_error(SchemaShard::InvalidTenantError)
      end
    end

    it 'switches MySQL database using USE and restores previous database' do
      conn = double('MysqlConn')
      allow(conn).to receive(:select_value).with('SELECT DATABASE()').and_return('app_main')
      allow(conn).to receive(:clear_cache!)
      expect(conn).to receive(:execute).with('USE `tenant_acme`').ordered
      expect(conn).to receive(:execute).with('USE `app_main`').ordered

      adapter.switch_namespace(conn, 'tenant_acme') { :ok }
    end

    it 'does not query MariaDB-only @@in_transaction on MySQL 8 connections' do
      raw  = double('TrilogyClient', server_status: 0)
      conn = double('Mysql8Conn', open_transactions: 0, raw_connection: raw, mariadb?: false)
      expect(conn).not_to receive(:select_value)

      expect(adapter.non_idle_transaction?(conn)).to be(false)
    end

    it 'detects open transaction via SERVER_STATUS_IN_TRANS flag' do
      raw  = double('TrilogyClient', server_status: 0x0001)
      conn = double('Mysql8Conn', open_transactions: 0, raw_connection: raw, mariadb?: false)

      expect(adapter.non_idle_transaction?(conn)).to be(true)
    end

    it 'does not discard clean connections on trilogy < 2.12.0 when Result#in_transaction? is absent' do
      stub_const('::Trilogy::Result', Class.new)
      result = double('TrilogyOldResult')
      raw    = double('TrilogyOldClient')
      allow(raw).to receive(:query).with('SELECT 1').and_return(result)
      conn = double('TrilogyConn', open_transactions: 0, raw_connection: raw, mariadb?: false)

      expect(adapter.non_idle_transaction?(conn)).to be(false)
    end

    it 'fails closed when raw_connection is nil' do
      conn = double('MysqlDeadConn', open_transactions: 0, raw_connection: nil)
      expect(adapter.non_idle_transaction?(conn)).to be(true)
    end

    it 'fails closed when default_namespace is blank during reset' do
      conn = double('MysqlConn')
      expect do
        adapter.verify_and_reset_default_namespace!(conn, default_namespace: '')
      end.to raise_error(SchemaShard::TaintedConnectionError)
    end
  end

  describe SchemaShard::DatabaseAdapters::Postgresql do
    subject(:adapter) { described_class.instance }

    it 'rejects invalid schema identifiers in format_search_path' do
      expect do
        adapter.format_search_path(['public', 'bad"; DROP TABLE users; --'])
      end.to raise_error(SchemaShard::InvalidTenantError)
    end

    it 'propagates search_path restoration errors when the block succeeded cleanly' do
      conn = double('PgConn', schema_search_path: '"public"', clear_cache!: nil)
      allow(conn).to receive(:schema_search_path=).with('"tenant_a"')
      allow(conn).to receive(:schema_search_path=).with('"public"').and_raise(StandardError, 'restore failed')

      expect do
        adapter.switch_namespace(conn, 'tenant_a') { :ok }
      end.to raise_error(StandardError, 'restore failed')
    end

    it 'preserves the original in-flight exception if search_path restoration also raises' do
      conn = double('PgConn', schema_search_path: '"public"', clear_cache!: nil)
      allow(conn).to receive(:schema_search_path=).with('"tenant_a"')
      allow(conn).to receive(:schema_search_path=).with('"public"').and_raise(StandardError, 'restore failed')

      expect do
        adapter.switch_namespace(conn, 'tenant_a') { raise 'original boom' }
      end.to raise_error(RuntimeError, 'original boom')
    end

    it 'does not call restore_search_path if initial schema_search_path= setup fails' do
      conn = double('PgConn', schema_search_path: '"public"')
      allow(conn).to receive(:schema_search_path=).with('"tenant_a"').and_raise(StandardError, 'socket closed')
      expect(conn).not_to receive(:schema_search_path=).with('"public"')

      expect do
        adapter.switch_namespace(conn, 'tenant_a') { :never }
      end.to raise_error(StandardError, 'socket closed')
    end
  end

  describe SchemaShard::DatabaseAdapters::Sqlite do
    subject(:adapter) { described_class.instance }

    it 'validates config with database only (no host required)' do
      expect { adapter.validate_config!('s1', { 'adapter' => 'sqlite3', 'database' => 'tmp/s1.sqlite3' }) }
        .not_to raise_error
    end

    it 'interpolates %{tenant} for per-tenant SQLite database templates' do
      cfg = { 'adapter' => 'sqlite3', 'database' => 'storage/tenants/%{tenant}.sqlite3' }
      expect(adapter.per_tenant_pool?(cfg)).to be(true)

      resolved = adapter.resolve_shard_config(cfg, tenant: 'acme')
      expect(resolved['database']).to eq('storage/tenants/acme.sqlite3')
    end

    it 'fails closed when switching tenants on a non-template SQLite shard' do
      cfg = { 'adapter' => 'sqlite3', 'database' => 'storage/shared.sqlite3' }
      expect do
        adapter.switch_namespace(double('Conn'), 'acme', shard_config: cfg) { :never }
      end.to raise_error(SchemaShard::ConfigurationError)
    end

    it 'rejects path traversal in SQLite tenant names' do
      expect do
        adapter.validate_tenant!('../secret', default_namespace: nil)
      end.to raise_error(SchemaShard::InvalidTenantError)
    end

    it 'returns nil for default_namespace_for and fails closed when raw_connection is nil' do
      expect(adapter.default_namespace_for({ 'database' => 'a.sqlite3' }, configured_default: 'public')).to be_nil
      dead_conn = double('SqliteDeadConn', open_transactions: 0, raw_connection: nil)
      expect(adapter.non_idle_transaction?(dead_conn)).to be(true)
    end
  end

  describe SchemaShard::DatabaseAdapters::Generic do
    subject(:adapter) { described_class.instance }

    it 'fails closed on switch_namespace' do
      expect do
        adapter.switch_namespace(double('Conn'), 'acme') { :never }
      end.to raise_error(SchemaShard::ConfigurationError)
    end
  end
end
