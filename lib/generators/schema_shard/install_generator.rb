# frozen_string_literal: true

require 'rails/generators'

module SchemaShard
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Creates a SchemaShard initializer and config/shards.yml template.'

      def copy_initializer
        template 'initializer.rb.tt', 'config/initializers/schema_shard.rb'
      end

      def copy_shards_config
        template 'shards.yml.tt', 'config/shards.yml'
      end
    end
  end
end
