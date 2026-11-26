# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe 'SQLite3 live integration' do
  let(:tmpdir) { Dir.mktmpdir('schema_shard_sqlite_') }
  let(:primary_db) { File.join(tmpdir, 'primary.sqlite3') }
  let(:shard_db) { File.join(tmpdir, 'shard01.sqlite3') }
  let(:tenant_template) { File.join(tmpdir, 'tenant_%{tenant}.sqlite3') }

  let(:item_model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = 'items'
    end
  end

  before do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: primary_db)
    ActiveRecord::Base.connection.create_table(:items, force: true) { |t| t.string :name }
    item_model.create!(name: 'primary_item')

    # Seed shard01 DB and two per-tenant DBs
    [
      [shard_db, 'shard01_item'],
      [File.join(tmpdir, 'tenant_acme.sqlite3'), 'acme_item'],
      [File.join(tmpdir, 'tenant_globex.sqlite3'), 'globex_item']
    ].each do |db_path, seed_name|
      pool_cfg = ActiveRecord::ConnectionAdapters::PoolConfig.new(
        ActiveRecord::Base,
        ActiveRecord::DatabaseConfigurations::HashConfig.new('test', db_path, { adapter: 'sqlite3', database: db_path }),
        :writing,
        :seed
      )
      pool = ActiveRecord::ConnectionAdapters::ConnectionPool.new(pool_cfg)
      pool.with_connection do |conn|
        conn.create_table(:items, force: true) { |t| t.string :name }
        conn.execute("INSERT INTO items (name) VALUES ('#{seed_name}')")
      end
      pool.disconnect!
    end

    SchemaShard.configure do |config|
      config.env            = 'test'
      config.tenant_adapter = :native
      config.tenant_mode    = :strict
      config.shards         = {
        'test' => {
          'shard01' => { 'adapter' => 'sqlite3', 'database' => shard_db },
          'tenants' => { 'adapter' => 'sqlite3', 'database' => tenant_template }
        }
      }
    end
  end

  after do
    SchemaShard.cleanup_connection_pools!
    ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
    FileUtils.rm_rf(tmpdir)
  end

  it 'routes queries to a read-only shard via .on_shard and restores primary afterwards' do
    expect(item_model.pluck(:name)).to eq(['primary_item'])

    shard_names = SchemaShard.on_shard('shard01') do
      item_model.pluck(:name)
    end

    expect(shard_names).to eq(['shard01_item'])
    expect(item_model.pluck(:name)).to eq(['primary_item'])
  end

  it 'prevents writes on a read-only SQLite shard and allows writes when read_only: false' do
    expect do
      SchemaShard.on_shard('shard01', read_only: true) do
        item_model.create!(name: 'blocked')
      end
    end.to raise_error(ActiveRecord::ReadOnlyError)

    SchemaShard.on_shard('shard01', read_only: false) do
      item_model.create!(name: 'written_to_shard')
    end

    expect(SchemaShard.on_shard('shard01') { item_model.pluck(:name) })
      .to contain_exactly('shard01_item', 'written_to_shard')
    expect(item_model.pluck(:name)).to eq(['primary_item'])
  end

  it 'isolates per-tenant SQLite database files using LRU pooled connections' do
    acme_items   = SchemaShard.with('acme', shard_key: 'tenants') { item_model.pluck(:name) }
    globex_items = SchemaShard.with('globex', shard_key: 'tenants') { item_model.pluck(:name) }

    expect(acme_items).to eq(['acme_item'])
    expect(globex_items).to eq(['globex_item'])
    expect(SchemaShard.pool_count).to eq(2)
  end
end
