# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe SchemaShard::ConfigLoader do
  let(:configuration) { SchemaShard::Configuration.new }
  let(:loader) { described_class.new(configuration: configuration) }

  before do
    configuration.env = 'test'
  end

  it 'loads standard top-level YAML without a root key' do
    Tempfile.create(['shards', '.yml']) do |f|
      f.write(<<~YAML)
        test:
          shard01:
            adapter: postgresql
            host: localhost
            database: app_test
      YAML
      f.flush

      configuration.config_path = f.path
      cfg = loader.fetch!('shard01')
      expect(cfg['host']).to eq('localhost')
      expect(cfg).to be_frozen
    end
  end

  it 'supports custom config_root_key and resolves url: into adapter/host/database' do
    Tempfile.create(['shards', '.yml']) do |f|
      f.write(<<~YAML)
        custom_shards:
          test:
            shard01:
              url: postgres://readonly_user:secret@replica.internal:5432/app_test
      YAML
      f.flush

      configuration.config_path     = f.path
      configuration.config_root_key = 'custom_shards'
      cfg = loader.fetch!('shard01')
      expect(cfg['adapter']).to eq('postgresql')
      expect(cfg['host']).to eq('replica.internal')
      expect(cfg['database']).to eq('app_test')
      expect(cfg['username']).to eq('readonly_user')
    end
  end

  it 'supports in-memory Proc shard configuration' do
    configuration.shards = -> { { test: { replica: { adapter: 'sqlite3', database: ':memory:' } } } }
    cfg = loader.fetch!('replica')
    expect(cfg['adapter']).to eq('sqlite3')
  end
end
