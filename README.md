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
  config.config_root_key    = nil        # optional top-level YAML key if your file nests shards under a key
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

### Example `config/shards.yml`

```yaml
production:
  pg_replica:
    adapter: postgresql
    url: <%= ENV['PG_REPLICA_URL'] %>

  mysql_replica:
    adapter: trilogy
    host: mysql-replica.internal
    database: app_production
    username: readonly_user
    password: <%= ENV['MYSQL_REPLICA_PASSWORD'] %>

  sqlite_tenants:
    adapter: sqlite3
    database: storage/tenants/%{tenant}.sqlite3
```

### Production Notes

- **Read-Only Defense in Depth**: `read_only: true` applies both `ActiveRecord::Base.while_preventing_writes` (which prevents writes thread-wide for the duration of the block, including `excluded_models`) and DB-level session read-only flags. In production, always back read replicas with a **read-only database role/user** as well.
- **Open Transactions & Nested Switches**: Nested different-tenant switches inside an open database transaction are rejected fail-closed (`SchemaShard::TaintedConnectionError`), and the tainted pool frame blocks any further queries even if the error is rescued.
- **MySQL 8 / Trilogy**: `trilogy >= 2.12.0` is recommended for live `Trilogy::Result#in_transaction?` protocol inspection on MySQL 8; MariaDB automatically uses `@@in_transaction`.
- **Fast-Path Live Verification**: Set `config.live_verify_fast_path = true` if application code mutates `search_path` or `USE` via raw SQL outside `SchemaShard.with`. Avoid wrapping a nested `SchemaShard.with` inside an out-of-band `Apartment::Tenant.switch` call.
- **Metrics Cardinality**: Per-shard metrics are bounded by `config.max_tracked_shards` (default `100`, bucketing overflow into `_other`). Call `SchemaShard.reset_metrics!` if you rotate dynamic shard keys.
- **Fiber Concurrency (Falcon / Async)**: Set `config.active_support.isolation_level = :fiber` in Rails 8 so `ActiveSupport::IsolatedExecutionState` isolates shard context per Fiber.
- **Standalone / Non-Rails Apps**: Call `SchemaShard.install!` once at boot to prepend `SchemaShard::ConnectionPatch` onto `ActiveRecord::Base`.

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

The gem is available as open source under the terms of the [MIT License](https://github.com/syrens/schema_shard/blob/main/LICENSE.txt).
