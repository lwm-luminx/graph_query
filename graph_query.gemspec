# frozen_string_literal: true

require_relative 'lib/graph_query/version'

Gem::Specification.new do |spec|
  spec.name = 'graph_query'
  spec.version = GraphQuery::VERSION
  spec.authors = ['Love Wins Media, Inc.']
  spec.summary = 'Graph traversals (Cypher-style paths, variable-length hops) for Active Record on PostgreSQL'
  spec.description = 'Declare edges on Active Record models from their associations, join tables or SQL, then walk ' \
                     'them with recursive CTEs: fixed and variable-length hops, both directions, node and edge ' \
                     'filters, linear Cypher-style patterns, and results that come back as Active Record relations.'
  spec.license = 'Nonstandard'
  spec.required_ruby_version = '>= 4.0'
  spec.files = Dir['lib/**/*', 'README.md']
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.add_dependency 'activerecord', '>= 7.1'
  spec.add_dependency 'pg', '>= 1.5'
end
