# frozen_string_literal: true

require_relative 'lib/graph_query/version'

Gem::Specification.new do |spec|
  spec.name = 'graph_query'
  spec.version = GraphQuery::VERSION
  spec.authors = ['Love Wins Media, Inc.']
  spec.summary = 'Graph traversals and Cypher queries for Active Record on PostgreSQL, on recursive CTEs'
  spec.description = 'Declare edges on Active Record models from their associations, join tables or SQL, then walk ' \
                     'them with recursive CTEs: fixed and variable-length hops, both directions, node and edge ' \
                     'filters, Cypher queries (MATCH, WHERE, RETURN), and results that come back as Active Record ' \
                     'relations.'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0'
  spec.files = Dir['lib/**/*', 'sig/**/*.rbs', 'rbi/**/*.rbi', 'docs/*.md', 'README.md', 'CHANGELOG.md', 'LICENSE.txt']
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.homepage = 'https://lwm-luminx.github.io/graph_query/'
  spec.metadata['source_code_uri'] = 'https://github.com/lwm-luminx/graph_query'
  spec.metadata['changelog_uri'] = 'https://github.com/lwm-luminx/graph_query/blob/main/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://lwm-luminx.github.io/graph_query/'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/lwm-luminx/graph_query/issues'

  spec.add_dependency 'activerecord', '>= 7.1'
  spec.add_dependency 'pg', '>= 1.5'
end
