# frozen_string_literal: true

require_relative 'lib/schema_shard/version'

Gem::Specification.new do |spec|
  spec.name = 'schema_shard'
  spec.version = SchemaShard::VERSION
  spec.authors = ['Raynald Serenas (Syrns)']
  spec.email = ['raynald.serenas@gmail.com']

  spec.summary = 'Rails 8-first database sharding and read-replica routing with optional multi-tenant isolation.'
  spec.description = <<~DESC.strip
    SchemaShard provides dynamic, LRU-managed database shard and read-replica connection
    pooling for Rails 8+ applications with optional, fail-closed multi-tenant isolation
    (PostgreSQL schemas via ros-apartment or native search_path, MySQL/Trilogy databases,
    SQLite3 per-tenant files, or pure shard-only routing). Includes dual-layer read-only
    enforcement, connection hygiene, fork safety, and Prometheus/StatsD observability.
  DESC
  spec.homepage = 'https://github.com/syrens/schema_shard'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/syrens/schema_shard'
  spec.metadata['changelog_uri'] = 'https://github.com/syrens/schema_shard/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/syrens/schema_shard/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('{lib,sig}/**/*') + %w[LICENSE.txt README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord', '>= 8.0', '< 9.0'
  spec.add_dependency 'activesupport', '>= 8.0', '< 9.0'
  spec.add_dependency 'concurrent-ruby', '~> 1.2'
end
