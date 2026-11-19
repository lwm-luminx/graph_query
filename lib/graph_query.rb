# frozen_string_literal: true

require 'active_record'
require 'active_support/concern'
require 'pg'
require 'graph_query/version'

# Graph traversals for Active Record on PostgreSQL. Models declare edges (from associations, join models or SQL);
# queries walk them with recursive CTEs and come back as relations. See README.md.
#
#   class Locale < ApplicationRecord
#     graph_edge :contains, association: :children
#     graph_edge :has_venue, association: :venues
#   end
#
#   Locale.where(slug: 'washington').traverse(:contains, depth: 0..).traverse(:has_venue)   # every venue in the state
#   GraphQuery.match('(s:Locale)-[:contains*0..]->()-[:has_venue]->(v:Venue)', s: Locale.where(slug: 'washington'))
module GraphQuery
  class Error < StandardError; end
  # The step names edges that don't leave the nodes it starts on.
  class NoEdges < Error; end
  # The walk reaches several models and the caller asked for one relation.
  class AmbiguousResult < Error; end
  # A pattern or Cypher query that can't be read.
  class PatternError < Error; end
  # Cypher that reads fine but asks for something graph_query doesn't do (comparing two variables, say).
  class UnsupportedCypher < Error; end

  autoload :Age, 'graph_query/age'
  autoload :Associations, 'graph_query/associations'
  autoload :Compiler, 'graph_query/compiler'
  autoload :Cypher, 'graph_query/cypher'
  autoload :Edge, 'graph_query/edge'
  autoload :Match, 'graph_query/match'
  autoload :Model, 'graph_query/model'
  autoload :Pattern, 'graph_query/pattern'
  autoload :Query, 'graph_query/query'
  autoload :Registry, 'graph_query/registry'
  autoload :Syntax, 'graph_query/syntax'

  # Where to start a walk: SQL selecting (node_type, node_id), and the models it can hold.
  StartSet = Data.define(:sql, :types)

  class << self
    # Unbounded steps that need a hop count (depth: 2.., with_depth, paths) stop after this many hops.
    attr_writer :max_depth

    def max_depth = @max_depth || 32

    def registry = @registry ||= Registry.new

    # A Query starting from a relation (or a record, or a model's every row).
    def from(scope) = Query.new(start_set(relation_for(scope)))

    # A Query starting from nodes of several models at once: [[type, id], ...].
    def from_pairs(pairs)
      raise ArgumentError, 'from_pairs needs at least one node' if pairs.empty?

      sets = pairs.group_by { type_name(it.first) }.map do |type, rows|
        model = type.constantize
        start_set(model.where(model.primary_key => rows.map(&:last)))
      end
      Query.new(StartSet.new(sql: sets.map { "(#{it.sql})" }.join(' UNION ALL '), types: sets.flat_map(&:types)))
    end

    # A Query starting from the nodes another query reaches.
    def from_query(query)
      Query.new(StartSet.new(sql: "SELECT node_type, node_id FROM (#{query.to_sql}) q",
                             types: query.types))
    end

    # Runs a Cypher-style linear pattern; see GraphQuery::Pattern for the syntax. Bindings name relations (or
    # Hashes of edge conditions) for the pattern's variables; params: gives values for $names in property maps. The
    # first node must be bound or labelled.
    def match(pattern, params: {}, **bindings) = Match.new(Pattern.parse(pattern, params), bindings)

    # Runs a Cypher query (MATCH ... WHERE ... RETURN ...); see GraphQuery::Cypher. Params give values for $names.
    def cypher(query, **params) = Cypher.new(query, params).result

    def start_set(relation)
      model = relation.klass
      ids = relation.unscope(:select).select(relation.arel_table[model.primary_key]).to_sql
      conn = model.connection
      type = conn.quote(model.polymorphic_name)
      id = conn.quote_column_name(model.primary_key)
      StartSet.new(sql: "SELECT #{type}::text AS node_type, start_rows.#{id} AS node_id FROM (#{ids}) start_rows",
                   types: [model.polymorphic_name])
    end

    def relation_for(scope)
      case scope
      when ActiveRecord::Relation then scope
      when ActiveRecord::Base then scope.class.where(scope.class.primary_key => scope.id)
      when Class then scope.all
      else raise ArgumentError, "can't walk from #{scope.inspect}"
      end
    end

    # The node type name of a model, relation, record or name.
    def type_name(thing)
      case thing
      when ActiveRecord::Relation then thing.klass.polymorphic_name
      when ActiveRecord::Base then thing.class.polymorphic_name
      when Class then thing.polymorphic_name
      else thing.to_s.camelize
      end
    end

    def model_for(thing) = thing.is_a?(Class) ? thing : type_name(thing).constantize
  end
end

ActiveSupport.on_load(:active_record) { include GraphQuery::Model }
