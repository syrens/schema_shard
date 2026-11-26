# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-11-26

### Fixed
- Hardened cross-shard `A -> B -> A` nesting and `.with` inside `.on_shard` dirty-frame propagation.
- Fixed namespace restoration error handling so restore failures on clean block exit are never swallowed while in-flight exceptions are preserved.
- Added Rails 8 `lease_connection` and `retrieve_connection` routing with `prevent_permanent_checkout: true` and `pool.release_connection` in inner `ensure`.
- Fixed `custom_connection_model?` via `connection_class_for_self` and `primary_class?` to protect `connects_to` subclasses (`SolidQueue::Job`, `SolidCache::Entry`, etc.).
- Fixed fork safety to call `ConnectionPool#discard!` (never `disconnect!`).
- Added `ConnectionUrlResolver` support for `url:` shard configs and SQLite `%{tenant}` URL templates.
- Fixed MySQL 8 / Trilogy `non_idle_transaction?` fail-closed handling and `Sqlite#default_namespace_for`.

## [0.1.0] - 2026-11-26

### Added
- Initial Rails 8-first release of `schema_shard`.
- Multi-database adapter architecture supporting PostgreSQL (`postgresql`, `postgis`), MySQL/MariaDB (`mysql2`, `trilogy`), SQLite3 (`sqlite3`), and generic ActiveRecord adapters.
- Pluggable tenant adapters: `:auto`, `:apartment` (`ros-apartment`), `:native` (zero-dependency DB switching), `:none` (pure shard routing), plus custom adapter support.
- Flexible tenant modes (`:strict`, `:optional`, `:none`) and explicit `SchemaShard.on_shard` / `SchemaShard.with_public` APIs.
- Dual-layer read-only protection (`ActiveRecord::Base.while_preventing_writes` + database-level read-only session settings).
- Fail-closed connection sanitization and tainted connection discarding.
- Race-free LRU connection pool registry using Dekker-style atomic refcounting (`PoolEntry`).
- Rails 8 `ActiveSupport::IsolatedExecutionState` support, Railtie integration, fork safety (`Process._fork` + `discard_pools_after_fork!`), Sidekiq middleware, optional SQL query logger, and `rails g schema_shard:install` generator.
- Built-in Prometheus and StatsD observability formatters.
