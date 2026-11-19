# frozen_string_literal: true

module GraphQuery
  # One kind of edge between two node models, read from a table: each row whose source and target columns are both
  # set is one edge from the source node to the target node.
  #
  # Edges come from an association (belongs_to, has_many/has_one, or has_many :through a join model), from a join
  # model named outright, or from SQL that selects source_id and target_id. Node and model names are kept as strings
  # and looked up when a query runs, so code reloading never leaves a stale class behind.
  class Edge
    attr_reader :name, :from, :to, :table_model, :source_column, :target_column, :conditions, :sql, :declared_by

    # name: the edge's name (a Symbol). from/to: node model names. table_model: the model whose table holds the
    # rows. conditions: [scope Proc or Hash, ...] applied to that table. sql: instead of a table, SQL selecting
    # source_id and target_id.
    def initialize(name:, from:, to:, declared_by:, table_model: nil, source_column: nil, target_column: nil,
                   conditions: [], sql: nil)
      @name = name.to_sym
      @from = from.to_s
      @to = to.to_s
      @declared_by = declared_by.to_s
      @table_model = table_model&.to_s
      @source_column = source_column&.to_s
      @target_column = target_column&.to_s
      @conditions = conditions.compact
      @sql = sql
      return if @sql || (@table_model && @source_column && @target_column)

      raise ArgumentError,
            "edge #{name} needs a table or SQL"
    end

    # What makes two declarations the same edge, so that reloading a model replaces its edges instead of adding more.
    def key = [declared_by, name, from, to, table_model, source_column, target_column, sql]

    # SQL for these edges walked in a direction, as rows (from_type, from_id, to_type, to_id): out goes source to
    # target, in goes target to source. edge_where filters the edge table's rows (not for SQL edges). With bound:,
    # only edges leaving the current row of that alias (node_type, node_id), for a LATERAL join that can use the
    # edge table's indexes.
    def rows_sql(direction, edge_where: nil, bound: nil)
      tail, head = direction == :in ? [to, from] : [from, to]
      tail_id, head_id = direction == :in ? %w[target_id source_id] : %w[source_id target_id]
      conn = ActiveRecord::Base.connection
      <<~SQL.squish
        SELECT #{conn.quote(tail)}::text AS from_type, edge_rows.#{tail_id} AS from_id,
               #{conn.quote(head)}::text AS to_type, edge_rows.#{head_id} AS to_id
        FROM (#{source_sql(edge_where)}) edge_rows
        #{"WHERE edge_rows.#{tail_id} = #{bound}.node_id AND #{bound}.node_type = #{conn.quote(tail)}" if bound}
      SQL
    end

    def model = table_model&.constantize

    # Whether rows of this edge can meet an edge filter. Like a missing property in Cypher, an edge kept somewhere
    # without the filter's columns never matches it; SQL edges match no filter.
    def filterable_by?(edge_where)
      return true if edge_where.blank?
      return false if sql
      return true unless edge_where.is_a?(Hash)

      edge_where.keys.all? do |key|
        key.is_a?(Hash) || model.column_names.include?(key.to_s) || model.reflect_on_association(key)
      end
    end

    def inspect = "#<GraphQuery::Edge #{from} -[:#{name}]-> #{to}>"

    private

    def source_sql(edge_where)
      if sql
        raise ArgumentError, "edge #{inspect} is SQL, so it can't take edge filters" if edge_where.present?

        return sql
      end

      relation = model.unscoped
      table = model.arel_table
      relation = relation.where.not(table[source_column].eq(nil)).where.not(table[target_column].eq(nil))
      conditions.each { relation = apply(relation, it) }
      relation = apply(relation, edge_where) if edge_where.present?
      relation.unscope(:order, :limit, :offset, :select)
              .select(table[source_column].as('source_id'), table[target_column].as('target_id'))
              .to_sql
    end

    def apply(relation, condition)
      case condition
      when Hash, String, Array then relation.where(condition)
      when ActiveRecord::Relation then relation.merge(condition)
      when Proc
        if condition.arity.positive?
          raise ArgumentError,
                "edge #{inspect}: scopes that take the owner record can't be walked"
        end

        relation.instance_exec(&condition) || relation
      else raise ArgumentError, "edge #{inspect}: unknown condition #{condition.inspect}"
      end
    end
  end
end
