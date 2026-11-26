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
      expect(conn).to receive(:execute).with('USE `tenant_acme`').ordered
      expect(conn).to receive(:execute).with('USE `app_main`').ordered

      adapter.switch_namespace(conn, 'tenant_acme') { :ok }
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

    it 'rejects path traversal in SQLite tenant names' do
      expect do
        adapter.validate_tenant!('../secret', default_namespace: nil)
      end.to raise_error(SchemaShard::InvalidTenantError)
    end
  end
end
