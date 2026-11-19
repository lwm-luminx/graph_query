# frozen_string_literal: true

module GraphQuery
  # Compiles a Query to one WITH RECURSIVE statement. Each node set is a CTE (g0 the start, gN after step N) with
  # columns node_type and node_id, plus what the caller asked to carry: origin_type/origin_id, path, depth.
  #
  # A step of one hop is a join. A longer step is a recursive CTE: bounded steps (depth: 1..3) keep a hop count and
  # stop at the bound; unbounded ones (depth: 0.. or 1..) keep a set of nodes and stop when no new node turns up,
  # so cycles end them. Unbounded steps that also need a hop count (depth: 2.., or with_depth) stop at
  # GraphQuery.max_depth. Paths never revisit a node.
  class Compiler
    attr_reader :types

    def initialize(query, origin: false, depth: false, path: false)
      @query = query
      @origin = origin
      @depth = depth
      @path = path
      @ctes = []
      @types = [query.start.types]
      compile
    end

    def sql
      last = "g#{@query.steps.size}"
      "WITH RECURSIVE #{@ctes.join(', ')} SELECT * FROM #{last}"
    end

    private

    def conn = ActiveRecord::Base.connection

    def carry = [*(%w[origin_type origin_id] if @origin), *('path' if @path)]

    def compile
      start = @query.start
      origin = @origin ? 'node_type AS origin_type, node_id AS origin_id, ' : ''
      path = @path ? "ARRAY[#{key('node_type', 'node_id')}] AS path, " : ''
      @ctes << "g0 AS (SELECT DISTINCT #{origin}#{path}node_type, node_id FROM (#{start.sql}) graph_query_start)"
      @query.steps.each_with_index { |step, index| compile_step(step, index + 1) }
    end

    def compile_step(step, index)
      types_in = @types.last
      edges, reached = walk_edges(step, types_in)
      @types << arrival_types(step, types_in, reached)
      last = index == @query.steps.size
      want_depth = @depth && last
      edges_sql = lambda do |bound|
        edges.map { |edge, dir| "(#{edge.rows_sql(dir, edge_where: step.edge_where, bound:)})" }.join(' UNION ALL ')
      end
      prev = "g#{index - 1}"
      name = "g#{index}"

      if @path
        compile_paths(step, name, prev, edges_sql, want_depth)
      elsif step.max == 1 && !want_depth
        compile_hop(step, name, prev, edges_sql)
      elsif step.max.nil? && step.min <= 1 && !want_depth
        compile_closure(step, name, prev, edges_sql)
      else
        compile_bounded(step, name, prev, edges_sql, want_depth)
      end
    end

    # One hop (or none, for depth: 0..1).
    def compile_hop(step, name, prev, edges_sql)
      parts = []
      parts << stay(prev) if step.min.zero?
      parts << hop(prev, 'p', edges_sql, step)
      @ctes << "#{name}(#{cols_list}node_type, node_id) AS (SELECT DISTINCT * FROM " \
               "(#{parts.join(' UNION ALL ')}) x WHERE #{arrive(step, 'x')})"
    end

    # Every node reachable in at least min (0 or 1) hops, as a set: ends on cycles.
    def compile_closure(step, name, prev, edges_sql)
      walk = "#{name}_walk"
      seed = step.min.zero? ? stay(prev) : hop(prev, 'p', edges_sql, step)
      @ctes << "#{walk}(#{cols_list}node_type, node_id) AS " \
               "(#{seed} UNION #{hop(walk, 'w', edges_sql, step)})"
      @ctes << "#{name}(#{cols_list}node_type, node_id) AS " \
               "(SELECT DISTINCT * FROM #{walk} x WHERE #{arrive(step, 'x')})"
    end

    # A hop count kept per row, stopping at max (or GraphQuery.max_depth).
    def compile_bounded(step, name, prev, edges_sql, want_depth)
      walk = "#{name}_walk"
      max = Integer(step.max || GraphQuery.max_depth)
      @ctes << "#{walk}(#{cols_list}node_type, node_id, depth) AS " \
               "(#{stay(prev, depth: true)} UNION #{hop(walk, 'w', edges_sql, step, max:)})"
      group = [*carry, 'node_type', 'node_id'].map { "x.#{it}" }.join(', ')
      depth_col = want_depth ? ', MIN(x.depth) AS depth' : ''
      @ctes << "#{name} AS (SELECT #{group}#{depth_col} FROM #{walk} x " \
               "WHERE x.depth >= #{Integer(step.min)} AND #{arrive(step, 'x')} GROUP BY #{group})"
    end

    # Every simple path: rows are walks, not nodes, so this is for showing routes, not for big graphs.
    def compile_paths(step, name, prev, edges_sql, want_depth)
      walk = "#{name}_walk"
      max = Integer(step.max || GraphQuery.max_depth)
      @ctes << "#{walk}(#{cols_list}node_type, node_id, depth) AS " \
               "(#{stay(prev, depth: true)} UNION ALL #{hop(walk, 'w', edges_sql, step, max:, path: true)})"
      list = [*carry, 'node_type', 'node_id', *('depth' if want_depth)].map { "x.#{it}" }.join(', ')
      @ctes << "#{name} AS (SELECT #{list} FROM #{walk} x " \
               "WHERE x.depth >= #{Integer(step.min)} AND #{arrive(step, 'x')})"
    end

    # The rows of set from, unmoved (depth 0).
    def stay(from, depth: false)
      "SELECT #{cols('p')}p.node_type, p.node_id#{', 0' if depth} FROM #{from} p"
    end

    # One hop from the rows of set from (as alias a) along the step's edges. With max, rows carry a depth and stop
    # there; with path, the path grows and never revisits a node.
    def hop(from, alias_name, edges_sql, step, max: nil, path: false)
      conditions = [through(step)]
      conditions << "#{alias_name}.depth < #{max}" if max
      conditions << "NOT (#{key('e.to_type', 'e.to_id')} = ANY(#{alias_name}.path))" if path
      "SELECT #{cols(alias_name, path_append: path)}e.to_type AS node_type, e.to_id AS node_id" \
        "#{", #{alias_name}.depth + 1" if max} FROM #{from} #{alias_name} " \
        "#{join(edges_sql, alias_name)} WHERE #{conditions.join(' AND ')}"
    end

    def cols_list = carry.empty? ? '' : "#{carry.join(', ')}, "

    # The carried columns from alias a; in a path step, the path grows by the node arrived at.
    def cols(alias_name, path_append: false)
      list = carry.map do |col|
        col == 'path' && path_append ? "#{alias_name}.path || #{key('e.to_type', 'e.to_id')}" : "#{alias_name}.#{col}"
      end
      list.map { "#{it}, " }.join
    end

    # The step's edges leaving each row of alias from, one LATERAL subquery per row so each edge table is read
    # through its index on the column that points back.
    def join(edges_sql, from) = "CROSS JOIN LATERAL (#{edges_sql.call(from)}) e"

    def key(type, id) = "(#{type} || ':' || #{id}::text)"

    # Edges this step may follow: those leaving the nodes it starts on and, for steps of more than one hop, those
    # leaving every node they reach.
    def walk_edges(step, types_in)
      seen = types_in.dup
      frontier = types_in
      chosen = []
      loop do
        found = GraphQuery.registry.walkable(frontier, step.names, step.direction)
                          .select { |edge, _| edge.filterable_by?(step.edge_where) } - chosen
        chosen.concat(found)
        heads = found.map { |edge, dir| dir == :in ? edge.from : edge.to }.uniq
        frontier = heads - seen
        seen |= heads
        break if frontier.empty? || step.max == 1
      end
      if chosen.empty?
        raise NoEdges,
              "no #{step.names&.join('|') || 'edges'} (#{step.direction}) from #{types_in.join(', ')}"
      end

      [chosen, chosen.map { |edge, dir| dir == :in ? edge.from : edge.to }.uniq]
    end

    def arrival_types(step, types_in, reached)
      types = step.min.zero? ? (types_in | reached) : reached
      types &= step.labels if step.labels
      wheres = step.where&.grep_v(Hash)
      types &= wheres.map { GraphQuery.type_name(it) } if wheres.present?
      raise NoEdges, "#{step.names&.join('|') || 'edges'} never reach #{step.labels&.join(', ')}" if types.empty?

      types
    end

    # The conditions a node must meet to be in the step's result.
    def arrive(step, from)
      conditions = []
      conditions << "#{from}.node_type IN (#{step.labels.map { conn.quote(it) }.join(', ')})" if step.labels
      if step.where
        options = step.where.map { member(it, from) }
        conditions << "(#{options.join(' OR ')})"
      end
      conditions.empty? ? 'TRUE' : conditions.join(' AND ')
    end

    # Every node the walk passes through must be in the through relations (nodes of other models pass).
    def through(step)
      return 'TRUE' unless step.through

      step.through.map do |scope|
        relation = GraphQuery.relation_for(scope)
        type = conn.quote(relation.klass.polymorphic_name)
        "(e.to_type <> #{type} OR e.to_id IN (#{ids(relation)}))"
      end.join(' AND ')
    end

    def member(scope, from)
      relation = if scope.is_a?(Hash)
                   unless @types.last.size == 1
                     raise AmbiguousResult,
                           "where: Hash needs one model, this step reaches #{@types.last.join(', ')}"
                   end

                   @types.last.first.constantize.where(scope)
                 else
                   GraphQuery.relation_for(scope)
                 end
      "(#{from}.node_type = #{conn.quote(relation.klass.polymorphic_name)} AND #{from}.node_id IN (#{ids(relation)}))"
    end

    def ids(relation)
      relation = relation.unscope(:order) unless relation.limit_value || relation.offset_value
      relation.unscope(:select).select(relation.arel_table[relation.klass.primary_key]).to_sql
    end
  end
end
