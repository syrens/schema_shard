# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'pg', '~> 1.5', require: false if ENV['PG_INTEGRATION'] == '1'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.65'
  gem 'sqlite3', '>= 2.0'
end
