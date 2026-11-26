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

  it 'fails closed when calling .with(tenant) on a non-template SQLite shard' do
    expect do
      SchemaShard.with('acme', shard_key: 'shard01') { item_model.pluck(:name) }
    end.to raise_error(SchemaShard::ConfigurationError)
  end

  it 'prevents sticky-lease leaks when Rails 8 lease_connection / retrieve_connection are used inside a block' do
    SchemaShard.configuration.shards = {
      'test' => {
        'shard01' => { 'adapter' => 'sqlite3', 'database' => shard_db, 'pool' => 1 }
      }
    }
    SchemaShard.reload_config!

    SchemaShard.on_shard('shard01') do
      expect(item_model.lease_connection).to equal(SchemaShard.active_connection)
      expect(item_model.retrieve_connection).to equal(SchemaShard.active_connection)
      expect(item_model.pluck(:name)).to eq(['shard01_item'])
    end

    expect(SchemaShard.total_active_connections).to eq(0)
  end

  it 'supports url:-configured SQLite shards end-to-end' do
    SchemaShard.configuration.shards = {
      'test' => {
        'url_shard' => { 'url' => "sqlite3://#{shard_db}" }
      }
    }
    SchemaShard.reload_config!

    expect(SchemaShard.on_shard('url_shard') { item_model.pluck(:name) }).to eq(['shard01_item'])
  end

  it 'does NOT hijack a real ActiveRecord connects_to abstract class and its concrete subclass' do
    queue_db = File.join(tmpdir, 'queue.sqlite3')
    queue_base = Class.new(ActiveRecord::Base) do
      self.abstract_class = true
    end
    stub_const('SpecQueueBase', queue_base)
    SpecQueueBase.establish_connection(adapter: 'sqlite3', database: queue_db)
    SpecQueueBase.connection.create_table(:jobs, force: true) { |t| t.string :title }

    queue_job = Class.new(SpecQueueBase) do
      self.table_name = 'jobs'
    end
    stub_const('SpecQueueJob', queue_job)
    SpecQueueJob.create!(title: 'dedicated_queue_job')

    SchemaShard.on_shard('shard01') do
      expect(SchemaShard.routable_model?(SpecQueueBase)).to be(false)
      expect(SchemaShard.routable_model?(SpecQueueJob)).to be(false)
      expect(SpecQueueJob.pluck(:title)).to eq(['dedicated_queue_job'])
      expect(item_model.pluck(:name)).to eq(['shard01_item'])
    end
  ensure
    queue_base&.connection_handler&.clear_all_connections!(:all)
  end

  it 'keeps parent shard pool healthy after a real Process.fork child discards inherited pools' do
    skip 'Process.fork not supported on this platform' unless Process.respond_to?(:fork)

    expect(SchemaShard.on_shard('shard01') { item_model.pluck(:name) }).to eq(['shard01_item'])
    expect(SchemaShard.pool_count).to eq(1)

    pid = Process.fork do
      SchemaShard.discard_pools_after_fork!
      exit!(SchemaShard.pool_count.zero? ? 0 : 1)
    end
    _, status = Process.wait2(pid)

    expect(status.exitstatus).to eq(0)
    expect(SchemaShard.on_shard('shard01') { item_model.pluck(:name) }).to eq(['shard01_item'])
  end
end
