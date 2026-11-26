# frozen_string_literal: true

require 'spec_helper'

if ENV['PG_INTEGRATION'] == '1'
  require 'pg'

  RSpec.describe 'PostgreSQL live integration' do
    let(:pg_host)     { ENV.fetch('PG_HOST', '127.0.0.1') }
    let(:pg_port)     { ENV.fetch('PG_PORT', '5432').to_i }
    let(:pg_user)     { ENV.fetch('PG_USER', 'postgres') }
    let(:pg_password) { ENV.fetch('PG_PASSWORD', 'postgres') }
    let(:pg_database) { ENV.fetch('PG_DATABASE', 'schema_shard_test') }

    let(:base_pg_config) do
      {
        'adapter' => 'postgresql',
        'host' => pg_host,
        'port' => pg_port,
        'username' => pg_user,
        'password' => pg_password,
        'database' => pg_database
      }
    end

    let(:item_model) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'items'
      end
    end

    before do
      ActiveRecord::Base.establish_connection(base_pg_config.transform_keys(&:to_sym))
      conn = ActiveRecord::Base.connection

      conn.execute('CREATE SCHEMA IF NOT EXISTS tenant_acme')
      conn.execute('CREATE SCHEMA IF NOT EXISTS tenant_globex')

      {
        'public' => 'public_row',
        'tenant_acme' => 'acme_row',
        'tenant_globex' => 'globex_row'
      }.each do |schema, seed_name|
        conn.execute(%(DROP TABLE IF EXISTS "#{schema}".items))
        conn.execute(%(CREATE TABLE "#{schema}".items (id serial PRIMARY KEY, name varchar NOT NULL)))
        conn.execute(%(INSERT INTO "#{schema}".items (name) VALUES ('#{seed_name}')))
      end

      SchemaShard.configure do |config|
        config.env            = 'test'
        config.default_shard  = 'pg_shard'
        config.tenant_adapter = :native
        config.tenant_mode    = :strict
        config.shards         = {
          'test' => {
            'pg_shard' => base_pg_config,
            'pg_shard_2' => base_pg_config.merge('checkout_timeout' => 6)
          }
        }
      end
    end

    after do
      SchemaShard.cleanup_connection_pools!
      ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
    end

    it 'isolates tenant queries via native PostgreSQL search_path and resets on exit' do
      acme_rows   = SchemaShard.with('tenant_acme') { item_model.pluck(:name) }
      globex_rows = SchemaShard.with('tenant_globex') { item_model.pluck(:name) }

      expect(acme_rows).to eq(['acme_row'])
      expect(globex_rows).to eq(['globex_row'])
      expect(item_model.pluck(:name)).to eq(['public_row'])
    end

    it 'handles nested same-shard different-tenant switches cleanly' do
      observed = []

      SchemaShard.with('tenant_acme') do
        observed << item_model.pluck(:name)
        SchemaShard.with('tenant_globex') do
          observed << item_model.pluck(:name)
        end
        observed << item_model.pluck(:name)
      end

      expect(observed).to eq([['acme_row'], ['globex_row'], ['acme_row']])
    end

    it 'preserves outer shard schema across A -> B -> A cross-shard nesting' do
      observed = []

      SchemaShard.with('tenant_acme', shard_key: 'pg_shard') do
        observed << item_model.pluck(:name)
        SchemaShard.with('tenant_globex', shard_key: 'pg_shard_2') do
          observed << item_model.pluck(:name)
          SchemaShard.with('tenant_globex', shard_key: 'pg_shard') do
            observed << item_model.pluck(:name)
          end
        end
        observed << item_model.pluck(:name)
      end

      expect(observed).to eq([['acme_row'], ['globex_row'], ['globex_row'], ['acme_row']])
    end

    it 'restores public schema when nesting .with inside .on_shard' do
      observed = []

      SchemaShard.on_shard('pg_shard') do
        observed << item_model.pluck(:name)
        SchemaShard.with('tenant_acme', shard_key: 'pg_shard') do
          observed << item_model.pluck(:name)
        end
        observed << item_model.pluck(:name)
      end

      expect(observed).to eq([['public_row'], ['acme_row'], ['public_row']])
      expect(SchemaShard.on_shard('pg_shard') { item_model.pluck(:name) }).to eq(['public_row'])
    end

    it 're-switches schema when search_path was changed out-of-band inside a block' do
      SchemaShard.with('tenant_acme') do
        ActiveRecord::Base.connection.schema_search_path = '"tenant_globex"'
        expect(SchemaShard.with('tenant_acme') { item_model.pluck(:name) }).to eq(['acme_row'])
      end
    end

    it 'supports shard-only routing (.on_shard) and explicit .with_public' do
      expect(SchemaShard.on_shard('pg_shard') { item_model.pluck(:name) }).to eq(['public_row'])
      expect(SchemaShard.with_public { item_model.pluck(:name) }).to eq(['public_row'])
    end

    it 'enforces dual-layer read-only protection (Ruby + PostgreSQL session variable) and allows read_only: false' do
      expect do
        SchemaShard.with('tenant_acme', read_only: true) do
          item_model.create!(name: 'blocked_by_ruby')
        end
      end.to raise_error(ActiveRecord::ReadOnlyError)

      expect do
        SchemaShard.with('tenant_acme', read_only: true) do
          ActiveRecord::Base.connection.raw_connection.exec("INSERT INTO items (name) VALUES ('blocked_by_pg')")
        end
      end.to raise_error(PG::ReadOnlySqlTransaction)

      SchemaShard.with('tenant_acme', read_only: false) do
        item_model.create!(name: 'written_to_acme')
      end

      expect(SchemaShard.with('tenant_acme') { item_model.pluck(:name) })
        .to contain_exactly('acme_row', 'written_to_acme')
      expect(SchemaShard.with('tenant_globex') { item_model.pluck(:name) })
        .to eq(['globex_row'])
    end

    it 'discards connections left in an open PostgreSQL transaction (fail-closed)' do
      before_discards = SchemaShard.metrics[:global][:connection_discards_total]

      SchemaShard.with('tenant_acme') do
        ActiveRecord::Base.connection.raw_connection.exec('BEGIN')
      end

      expect(SchemaShard.metrics[:global][:connection_discards_total]).to eq(before_discards + 1)
      expect(SchemaShard.with('tenant_globex') { item_model.pluck(:name) }).to eq(['globex_row'])
    end

    it 'fails closed on subsequent queries if outer block rescues nested TaintedConnectionError' do
      SchemaShard.with('tenant_acme') do
        begin
          SchemaShard.with('tenant_globex') do
            ActiveRecord::Base.connection.raw_connection.exec('BEGIN')
          end
        rescue SchemaShard::TaintedConnectionError
          # outer block attempts to continue after catching taint
        end

        expect { item_model.pluck(:name) }.to raise_error(SchemaShard::TaintedConnectionError)
      end

      expect(SchemaShard.with('tenant_acme') { item_model.pluck(:name) }).to eq(['acme_row'])
    end

    it 'maintains strict cross-tenant isolation under concurrent threads' do
      results = Queue.new

      threads = Array.new(6) do |i|
        tenant = i.even? ? 'tenant_acme' : 'tenant_globex'
        expected = i.even? ? ['acme_row'] : ['globex_row']

        Thread.new do
          5.times do
            actual = SchemaShard.with(tenant) { item_model.pluck(:name) }
            results << [tenant, expected, actual]
          end
        end
      end

      threads.each(&:join)

      until results.empty?
        _tenant, expected, actual = results.pop
        expect(actual).to eq(expected)
      end
    end
  end
end
