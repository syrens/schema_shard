# frozen_string_literal: true

require 'spec_helper'

if ENV['MYSQL_INTEGRATION'] == '1'
  mysql_adapter = ENV.fetch('MYSQL_ADAPTER', 'trilogy')
  require mysql_adapter

  RSpec.describe "MySQL / MariaDB (#{mysql_adapter}) live integration" do
    let(:mysql_host)     { ENV.fetch('MYSQL_HOST', '127.0.0.1') }
    let(:mysql_port)     { ENV.fetch('MYSQL_PORT', '3306').to_i }
    let(:mysql_user)     { ENV.fetch('MYSQL_USER', 'root') }
    let(:mysql_password) { ENV.fetch('MYSQL_PASSWORD', 'root') }
    let(:mysql_database) { ENV.fetch('MYSQL_DATABASE', 'schema_shard_test') }

    let(:base_mysql_config) do
      cfg = {
        'adapter' => mysql_adapter,
        'host' => mysql_host,
        'port' => mysql_port,
        'username' => mysql_user,
        'password' => mysql_password,
        'database' => mysql_database
      }
      cfg['prepared_statements'] = true if mysql_adapter == 'mysql2'
      cfg
    end

    let(:item_model) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'items'
      end
    end

    before do
      ActiveRecord::Base.establish_connection(base_mysql_config.transform_keys(&:to_sym))
      conn = ActiveRecord::Base.connection

      %w[tenant_acme tenant_globex].each do |db|
        conn.execute("CREATE DATABASE IF NOT EXISTS `#{db}`")
      end

      {
        mysql_database => 'default_row',
        'tenant_acme' => 'acme_row',
        'tenant_globex' => 'globex_row'
      }.each do |db, seed_name|
        conn.execute("DROP TABLE IF EXISTS `#{db}`.items")
        conn.execute("CREATE TABLE `#{db}`.items (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL)")
        conn.execute("INSERT INTO `#{db}`.items (name) VALUES ('#{seed_name}')")
      end

      SchemaShard.configure do |config|
        config.env            = 'test'
        config.default_shard  = 'mysql_shard'
        config.tenant_adapter = :native
        config.tenant_mode    = :strict
        config.shards         = {
          'test' => {
            'mysql_shard' => base_mysql_config,
            'mysql_url' => {
              'url' => "#{mysql_adapter}://#{mysql_user}:#{mysql_password}@#{mysql_host}:#{mysql_port}/#{mysql_database}"
            }
          }
        }
      end
    end

    after do
      SchemaShard.cleanup_connection_pools!
      ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
    end

    it 'isolates tenant queries via USE and resets back to default database' do
      expect(SchemaShard.with('tenant_acme') { item_model.pluck(:name) }).to eq(['acme_row'])
      expect(SchemaShard.with('tenant_globex') { item_model.pluck(:name) }).to eq(['globex_row'])
      expect(SchemaShard.with_public { item_model.pluck(:name) }).to eq(['default_row'])
      expect(SchemaShard.on_shard('mysql_url') { item_model.pluck(:name) }).to eq(['default_row'])
    end

    it 'handles nested tenant switches cleanly with prepared_statements enabled' do
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

    it 'enforces dual-layer read_only: true (Ruby + MySQL transaction_read_only=1) and allows read_only: false' do
      expect do
        SchemaShard.with('tenant_acme', read_only: true) { item_model.create!(name: 'blocked') }
      end.to raise_error(ActiveRecord::ReadOnlyError)

      expect do
        SchemaShard.with('tenant_acme', read_only: true) do
          ActiveRecord::Base.connection.raw_connection.query("INSERT INTO items (name) VALUES ('blocked_by_mysql')")
        end
      end.to raise_error(StandardError)

      SchemaShard.with('tenant_acme', read_only: false) { item_model.create!(name: 'written') }
      expect(SchemaShard.with('tenant_acme') { item_model.pluck(:name) }).to contain_exactly('acme_row', 'written')
    end

    it 'discards connections left in an open raw transaction when driver reports transaction state' do
      before_discards = SchemaShard.metrics[:global][:connection_discards_total]

      SchemaShard.with('tenant_acme') do
        ActiveRecord::Base.connection.raw_connection.query('BEGIN')
      end

      can_detect = (defined?(Trilogy::Result) && Trilogy::Result.method_defined?(:in_transaction?)) ||
                   mysql_adapter == 'mysql2'
      expect(SchemaShard.metrics[:global][:connection_discards_total]).to eq(before_discards + 1) if can_detect
      expect(SchemaShard.with('tenant_globex') { item_model.pluck(:name) }).to eq(['globex_row'])
    end
  end
end
