# frozen_string_literal: true

module GraphQuery
  # A Pattern with its variables bound, run as Queries. #nodes gives the last node's matches (or any variable's:
  # nodes(:v)); a variable in the middle of the pattern gives only nodes that lie on a full match, found by walking
  # back from the end. Relation methods go to the last node's relation, as with Query.
  class Match
    attr_reader :pattern, :bindings

    def initialize(pattern, bindings)
      @pattern = pattern
      @bindings = bindings.transform_keys(&:to_sym)
      unknown = @bindings.keys - pattern.variables.keys - [:__start]
      raise PatternError, "#{unknown.join(', ')} not in the pattern" if unknown.any?
    end

    # The Query for the whole pattern (or up to node index upto).
    def query(upto = pattern.rels.size)
      pattern.rels.first(upto).each_with_index.reduce(GraphQuery.from(start)) do |query, (rel, i)|
        query.traverse(rel.names, depth: rel.max ? rel.min..rel.max : rel.min.., direction: rel.direction,
                                  **arrival(i + 1), edge_where: edge_binding(rel))
      end
    end

    # The nodes a variable (by default the last node) matches, as a relation.
    def nodes(var = nil, model: nil)
      index = var ? node_index(var) : pattern.nodes.size - 1
      forward = query(index)
      return forward.to_relation(model) if index == pattern.rels.size

      backward = backward_query(index)
      relation = forward.to_relation(model)
      ids = "SELECT node_id FROM (#{backward.to_sql}) back " \
            "WHERE node_type = #{relation.connection.quote(relation.klass.polymorphic_name)}"
      column = "#{relation.quoted_table_name}.#{relation.connection.quote_column_name(relation.klass.primary_key)}"
      relation.where(Arel.sql("#{column} IN (#{ids})"))
    end

    # Every path matching the whole pattern, as [[type, id], ...].
    delegate :paths, to: :query

    def to_relation(model = nil) = nodes(model:)

    def respond_to_missing?(name, include_private = false)
      ActiveRecord::Relation.method_defined?(name) || super
    end

    def method_missing(name, ...)
      return super unless ActiveRecord::Relation.method_defined?(name)

      nodes.public_send(name, ...)
    end

    private

    def start
      node = pattern.nodes.first
      scope = node_scope(0)
      return scope if scope
      raise PatternError, 'the first node needs a binding or one label' unless node.labels&.size == 1

      node.labels.first.constantize.all
    end

    # The conditions on node index i as traverse options.
    def arrival(index)
      node = pattern.nodes[index]
      options = {}
      options[:to] = node.labels if node.labels
      scope = node_scope(index)
      options[:where] = scope if scope
      options
    end

    # What node index i must be in: its binding (a relation, record or model) narrowed by its property map.
    def node_scope(index)
      node = pattern.nodes[index]
      bound = node.var && @bindings[node.var]
      bound ||= @bindings[:__start] if index.zero?
      return bound && GraphQuery.relation_for(bound) if node.props.blank?

      relation = if bound then GraphQuery.relation_for(bound)
                 elsif node.labels&.size == 1 then node.labels.first.constantize.all
                 else raise PatternError, "(#{node.var}) needs one label or a binding for its property map"
                 end
      relation.where(node.props)
    end

    # The rows a relationship's edges must match: its binding (a Hash or scope Proc) and its property map.
    def edge_binding(rel)
      bound = rel.var && @bindings[rel.var]
      return bound if rel.props.blank?
      return rel.props if bound.nil?
      raise PatternError, "[#{rel.var}] has a property map and a binding that isn't a Hash" unless bound.is_a?(Hash)

      bound.merge(rel.props)
    end

    def node_index(var)
      kind, index = pattern.variables[var.to_sym]
      raise PatternError, "#{var} is not a node in the pattern" unless kind == :node

      index
    end

    # From every full match's last node, walk the pattern backwards to node index, checking each node on the way.
    def backward_query(index)
      rels = pattern.rels
      (index...rels.size).reverse_each.reduce(GraphQuery.from_query(query)) do |query, i|
        rel = rels[i]
        options = i.zero? ? { where: start } : arrival(i)
        query.traverse(rel.names, depth: rel.max ? rel.min..rel.max : rel.min.., direction: flip(rel.direction),
                                  **options, edge_where: edge_binding(rel))
      end
    end

    def flip(direction) = { out: :in, in: :out, both: :both }.fetch(direction)
  end
end
