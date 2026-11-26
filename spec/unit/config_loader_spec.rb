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

  it 'supports custom config_root_key for legacy YAML layouts' do
    Tempfile.create(['shards', '.yml']) do |f|
      f.write(<<~YAML)
        szShards:
          test:
            shard01:
              adapter: postgresql
              url: postgres://localhost/app_test
      YAML
      f.flush

      configuration.config_path     = f.path
      configuration.config_root_key = 'szShards'
      cfg = loader.fetch!('shard01')
      expect(cfg['url']).to eq('postgres://localhost/app_test')
    end
  end

  it 'supports in-memory Proc shard configuration' do
    configuration.shards = -> { { test: { replica: { adapter: 'sqlite3', database: ':memory:' } } } }
    cfg = loader.fetch!('replica')
    expect(cfg['adapter']).to eq('sqlite3')
  end
end
