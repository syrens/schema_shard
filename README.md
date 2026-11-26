# SchemaShard

**Rails 8-first database sharding and read-replica routing with optional, fail-closed multi-tenant isolation.**

`schema_shard` gives Rails 8+ applications dynamic, LRU-managed shard and read-replica connection pooling across **PostgreSQL**, **MySQL / MariaDB** (`mysql2` & `trilogy`), **SQLite3**, and custom ActiveRecord adapters — with flexible tenant isolation (`ros-apartment`, native DB switching, or pure shard-only routing).

## Features

- **Multi-Database by Design**: Auto-detects the database engine per shard from `adapter:` in `config/shards.yml`:
  - **PostgreSQL (`postgresql`, `postgis`)**: `ros-apartment` or zero-dependency native `search_path` switching, `default_transaction_read_only = on`, and fail-closed `PG::PQTRANS_IDLE` verification.
  - **MySQL / MariaDB (`mysql2`, `trilogy`)**: `ros-apartment` or native `USE \`tenant_db\`` switching, `transaction_read_only = 1`, and open-transaction checks.
  - **SQLite3 (`sqlite3`)**: Shard-only routing or per-tenant `.sqlite3` file templates (`storage/tenants/%{tenant}.sqlite3`) backed by LRU pool eviction and `PRAGMA query_only = ON`.
  - **Generic / Custom**: Register custom database or tenant adapters via `SchemaShard::DatabaseAdapters.register`.
- **Flexible Tenant Modes**:
  - `:strict` *(default)* — Fail-closed. `nil`, blank, system schemas (`pg_*`, `information_schema`), or accidental `public` fallback raise `SchemaShard::InvalidTenantError`.
  - `:optional` — `nil` tenant gracefully falls back to the shard's default schema/database.
  - `:none` — Pure database sharding / read-replica routing with zero tenant switching.
  - `SchemaShard.on_shard('shard01')` — Explicit shard-only routing regardless of `tenant_mode`.
- **Dual-Layer Read-Only Protection**: Combines `ActiveRecord::Base.while_preventing_writes` in Ruby with DB-level read-only session settings.
- **Race-Free LRU Pool Lifecycle**: Atomic Dekker-style refcounting (`PoolEntry`) prevents races between active queries and concurrent pool eviction.
- **Rails 8 Native**: Uses `ActiveSupport::IsolatedExecutionState` (`:thread` & `:fiber` safe), `HashConfig`/`PoolConfig`, Railtie lazy loading, Rails Executor cleanup, and Ruby 3.1+ `Process._fork` safety.
- **Observability Out-of-the-Box**: Lock-free counters with built-in **Prometheus** and **StatsD** formatters plus an opt-in SQL query logger.

## Installation

Add to your `Gemfile`:

```ruby
gem 'schema_shard'
```

Install and generate the initializer and `config/shards.yml` template:

```bash
bundle install
bin/rails generate schema_shard:install
```

## Configuration

```ruby
# config/initializers/schema_shard.rb
SchemaShard.configure do |config|
  config.config_path        = Rails.root.join('config', 'shards.yml')
  config.config_root_key    = nil        # optional top-level YAML key (e.g. 'szShards')
  config.default_shard      = 'shard01'

  # :auto (Apartment if loaded, else :native), :apartment, :native, :none, or custom adapter
  config.tenant_adapter     = :auto

  # :strict (fail-closed), :optional (fallback to default), or :none (shard-only)
  config.tenant_mode        = :strict

  # Models that must never be routed to a shard connection
  config.excluded_models    = %w[Account]
  config.default_schema     = 'public'
  config.persistent_schemas = %w[shared_extensions]

  config.max_pools          = ENV.fetch('SCHEMA_SHARD_MAX_POOLS', 10).to_i
  config.cleanup_threshold  = ENV.fetch('SCHEMA_SHARD_CLEANUP_THRESHOLD', 8).to_i
  config.log_shard_queries  = Rails.env.development?
end
```

## Usage

### Multi-Tenant + Shard Routing (PostgreSQL, MySQL, SQLite)

```ruby
SchemaShard.with('acme_corp', shard_key: 'replica_1') do
  Order.where(status: 'paid').count
end
```

### Shard-Only Routing (No Schema/Tenant Selection)

```ruby
# Uses the shard's default schema/database regardless of tenant_mode
SchemaShard.on_shard('replica_1') do
  Order.where(status: 'paid').count
end
```

### Explicit Default (`public`) Schema Access

```ruby
SchemaShard.with_public(shard_key: 'replica_1') do
  Account.count
end
```

### Writable Shards

```ruby
SchemaShard.on_shard('write_shard_2', read_only: false) do
  AuditLog.create!(event: 'synced')
end
```

### Sidekiq & Puma Integration

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add SchemaShard::Middleware::Sidekiq
  end
end
```

Fork safety is enabled automatically on Ruby 3.1+ via `Process._fork`, or you can call `SchemaShard.discard_pools_after_fork!` explicitly in `config/puma.rb`:

```ruby
on_worker_boot do
  SchemaShard.discard_pools_after_fork!
end
```

### Observability (Prometheus & StatsD)

```ruby
SchemaShard.metrics             # => Hash snapshot (global, per_shard, pools, timestamp)
SchemaShard.prometheus_metrics  # => Prometheus text exposition format
SchemaShard.statsd_metrics      # => Array of StatsD/DogStatsD gauge descriptors
```

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
gem build schema_shard.gemspec
```

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
