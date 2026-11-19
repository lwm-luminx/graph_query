# frozen_string_literal: true

module GraphQuery
  # A walk: a start set of nodes and a list of steps, each following some edges one or more hops. It compiles to one
  # WITH RECURSIVE statement and reads like a relation of the nodes the last step reaches:
  #
  #   Locale.where(slug: 'seattle').traverse(:contains, depth: 0..).traverse(:has_venue).where(kind: 'bar')
  #
  # Relation methods (where, order, limit, pluck, count, each, ...) go to #to_relation, which needs the last step to
  # reach one model (or name one with to:). For walks that reach several models, use #pairs, #records or
  # #polymorphic. Each query is immutable: steps return a new one.
  class Query
    include Enumerable

    Step = Data.define(:names, :direction, :min, :max, :labels, :where, :through, :edge_where)

    attr_reader :start, :steps

    def initialize(start, steps = [])
      @start = start
      @steps = steps.freeze
    end

    # Follows edges named names (a Symbol, an Array, or nil for every edge) from the current nodes.
    #
    # depth: hops, as an Integer or a Range (1 by default; 0.. includes the nodes it starts from; 2..4; 1..).
    # direction: :out (source to target, the default), :in, or :both.
    # to: only arrive at these models (a model or an Array of them).
    # where: only arrive at nodes in this relation (or Array of relations, one per model); a Hash filters the one
    #   model the step reaches.
    # through: every node the walk passes through, the last included, must be in this relation (or Array, one per
    #   model; nodes of other models pass freely).
    # edge_where: a Hash (or scope Proc) each edge's row must match, for edges kept in tables.
    def traverse(names = nil, depth: 1, direction: :out, to: nil, where: nil, through: nil, edge_where: nil)
      min, max = depth_bounds(depth)
      unless %i[out in both].include?(direction)
        raise ArgumentError, "direction must be :out, :in or :both, not #{direction.inspect}"
      end

      names = names.nil? || names == :* ? nil : Array(names).map(&:to_sym)
      step = Step.new(names:, direction:, min:, max:, labels: list(to)&.map { GraphQuery.type_name(it) },
                      where: list(where), through: list(through), edge_where:)
      self.class.new(start, steps + [step])
    end

    def out(names = nil, **) = traverse(names, **, direction: :out)
    def inbound(names = nil, **) = traverse(names, **, direction: :in)
    def both(names = nil, **) = traverse(names, **, direction: :both)

    # The node models the walk can end on.
    def types = compiler.types.last

    # The walk as SQL rows (node_type, node_id), plus origin_type and origin_id (the start node each row came from)
    # with origin:, depth (hops in the last step; the fewest, unless path:) with depth:, and path (every node on the
    # way, as 'Type:id' text) with path:.
    def to_sql(origin: false, depth: false, path: false) = Compiler.new(self, origin:, depth:, path:).sql

    # The nodes of one model the walk reaches, as a relation you can keep chaining.
    def to_relation(model = nil)
      model = resolve_model(model)
      table = model.arel_table
      model.where(table[model.primary_key].in(Arel.sql(ids_sql(model))))
    end
    alias nodes to_relation

    # The same relation with each node's hop count in the last step selected as graph_depth.
    def with_depth(model = nil)
      model = resolve_model(model)
      conn = model.connection
      joined = "INNER JOIN (#{to_sql(depth: true)}) graph_query_nodes " \
               "ON graph_query_nodes.node_type = #{conn.quote(model.polymorphic_name)} " \
               "AND graph_query_nodes.node_id = #{model.quoted_table_name}.#{conn.quote_column_name(model.primary_key)}"
      model.joins(joined).select(model.arel_table[Arel.star], Arel.sql('graph_query_nodes.depth AS graph_depth'))
    end

    # [[type, id], ...] for every node reached, whatever its model.
    def pairs = connection.select_rows("SELECT DISTINCT node_type, node_id FROM (#{to_sql}) g")

    # Every node reached, loaded, whatever its model.
    def records
      pairs.group_by(&:first).flat_map { |type, rows| type.constantize.where(id: rows.map(&:last)).to_a }
    end

    # {start id => [nodes of model it reaches]}, for a dataloader batching many starts in one query.
    def by_origin(model = nil)
      model = resolve_model(model)
      rows = connection.select_rows(<<~SQL.squish)
        SELECT DISTINCT origin_id, node_id FROM (#{to_sql(origin: true)}) g
        WHERE node_type = #{connection.quote(model.polymorphic_name)}
      SQL
      found = model.where(model.primary_key => rows.map(&:last).uniq).index_by(&:id)
      rows.group_by(&:first).transform_values { |list| list.filter_map { found[it.last] } }
    end

    # Each path the walk takes, as [[type, id], ...] from the start node to the last one. Paths never repeat a node.
    def paths
      connection.select_values("SELECT path FROM (#{to_sql(path: true)}) g").map do |raw|
        PG::TextDecoder::Array.new.decode(raw).map { it.split(':', 2) }
      end
    end

    # Rows of scope whose polymorphic association (name: :target reads target_type/target_id) points at a node the
    # walk reaches: everything linked to anything under a venue, say.
    def polymorphic(scope, name)
      reflection = scope.klass.reflect_on_association(name)
      type_col, id_col = reflection ? [reflection.foreign_type, reflection.foreign_key] : ["#{name}_type", "#{name}_id"]
      table = scope.klass.quoted_table_name
      scope.where(Arel.sql("(#{table}.#{connection.quote_column_name(type_col)}, " \
                           "#{table}.#{connection.quote_column_name(id_col)}) " \
                           "IN (SELECT node_type, node_id FROM (#{to_sql}) graph_query_nodes)"))
    end

    def each(&) = to_relation.each(&)

    def respond_to_missing?(name, include_private = false)
      (types.size == 1 && ActiveRecord::Relation.method_defined?(name)) || super
    end

    def method_missing(name, ...)
      return super unless types.size == 1 && ActiveRecord::Relation.method_defined?(name)

      to_relation.public_send(name, ...)
    end

    def inspect = "#<GraphQuery::Query #{types.join('|')}: #{steps.size} step(s)>"

    def compiler = @compiler ||= Compiler.new(self)

    private

    def connection = ActiveRecord::Base.connection

    def ids_sql(model)
      "SELECT node_id FROM (#{to_sql}) graph_query_nodes WHERE node_type = #{connection.quote(model.polymorphic_name)}"
    end

    def resolve_model(model)
      return GraphQuery.model_for(model) if model

      return types.first.constantize if types.size == 1

      raise AmbiguousResult, "this walk reaches #{types.join(', ')}: name one, use to:, or use #pairs / #polymorphic"
    end

    # Array() would load a relation's records.
    def list(value) = value.nil? || value.is_a?(Array) ? value : [value]

    def depth_bounds(depth)
      case depth
      when Integer then [depth, depth]
      when Range
        min = depth.begin || 0
        max = depth.end && (depth.exclude_end? ? depth.end - 1 : depth.end)
        raise ArgumentError, "depth #{depth} is empty" if min.negative? || (max && max < min)

        [min, max]
      else raise ArgumentError, "depth must be an Integer or a Range, not #{depth.inspect}"
      end
    end
  end
end
