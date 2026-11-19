# frozen_string_literal: true

module GraphQuery
  # Writes to the graph through the edges models declare, inside one database transaction:
  #
  #   GraphQuery.transaction do |graph|
  #     hill = graph.create(Locale, name: 'Capitol Hill')
  #     graph.link(seattle, :contains, hill)                     # sets locales.parent_id
  #     graph.link(northwest, :contains, hill, via: 'LocaleGrouping', attributes: { role: 'core' })
  #     graph.relink(hill, :has_venue, eagle, from: downtown)    # moves the venue
  #     graph.unlink(seattle, :has_venue, closed_bar)
  #   end
  #
  # An edge is written where it is kept: a has_many edge sets the foreign key on the target's row, a belongs_to edge on
  # the source's row, and a join-model edge creates or deletes a join row (with the edge's Hash conditions as its
  # attributes). Rows are saved with save!/destroy!, so validations and callbacks run, and any error rolls every write
  # back. SQL edges can't be written.
  class Transaction
    Change = Data.define(:action, :edge, :from, :to, :record)

    # What was written, in order.
    attr_reader :changes

    def initialize
      @changes = []
    end

    # Adds the edge name from from to to. Already there: nothing changes. via: names the edge's table model when
    # several edges share the name; attributes: extra columns for a new join row.
    def link(from, name, to, via: nil, attributes: {})
      edge = edge_for(from, name, to, via)
      record = case kind(edge)
               when :target_row then point(row(edge, to), edge.source_column, from, edge)
               when :source_row then point(row(edge, from), edge.target_column, to, edge)
               else join_row(edge, from, to, attributes)
               end
      note(:link, edge, from, to, record)
    end

    # Removes the edge name from from to to. Not there: nothing changes.
    def unlink(from, name, to, via: nil)
      edge = edge_for(from, name, to, via)
      record = case kind(edge)
               when :target_row then clear(row(edge, to), edge.source_column, from)
               when :source_row then clear(row(edge, from), edge.target_column, to)
               else rows(edge, from, to).each(&:destroy!).first
               end
      note(:unlink, edge, from, to, record)
    end

    # Moves to from one source to another: unlink from from:, link to new_from.
    def relink(new_from, name, to, from:, via: nil, attributes: {})
      unlink(from, name, to, via:) unless from.nil?
      link(new_from, name, to, via:, attributes:)
    end

    # Whether the edge name runs from from to to.
    def linked?(from, name, to, via: nil)
      edge = edge_for(from, name, to, via)
      case kind(edge)
      when :target_row then row(edge, to)[edge.source_column] == from.id
      when :source_row then row(edge, from)[edge.target_column] == to.id
      else rows(edge, from, to).exists?
      end
    end

    def create(model, **attributes) = model.create!(**attributes).tap { note(:create, nil, nil, nil, it) }

    def update(record, **attributes) = record.tap { it.update!(**attributes) }.tap { note(:update, nil, nil, nil, it) }

    def destroy(record) = record.destroy!.tap { note(:destroy, nil, nil, nil, it) }

    private

    def note(action, edge, from, to, record)
      @changes << Change.new(action:, edge:, from:, to:, record:) if record
      record
    end

    # The one edge named name from from's model to to's model (or kept in via's table).
    def edge_for(from, name, to, via)
      from_type = GraphQuery.type_name(from)
      to_type = GraphQuery.type_name(to)
      GraphQuery.registry.load_model(to_type)
      edges = GraphQuery.registry.walkable([from_type], [name.to_sym], :out).map(&:first)
                        .select { it.to == to_type && !it.sql }
      edges = edges.select { it.table_model == GraphQuery.type_name(via) } if via
      raise NoEdges, "no writable #{name} edge from #{from_type} to #{to_type}" if edges.empty?
      return edges.first if edges.one?

      tables = edges.map(&:table_model).join(', ')
      raise AmbiguousResult, "#{name} from #{from_type} to #{to_type} is kept in #{tables}: pass via:"
    end

    # Where the edge's row is: the target's own row (has_many), the source's own row (belongs_to), or a join row.
    def kind(edge)
      key = edge.model.primary_key
      if edge.target_column == key && edge.table_model == edge.to then :target_row
      elsif edge.source_column == key && edge.table_model == edge.from then :source_row
      else :join_row
      end
    end

    # The node's row in the edge's table (the record itself when it is one).
    def row(edge, node)
      model = edge.model
      node.is_a?(model) ? node : model.find(node.id)
    end

    def point(record, column, node, edge)
      record.assign_attributes(hash_conditions(edge))
      record[column] = node.id
      return nil unless record.changed?

      record.save!
      record
    end

    def clear(record, column, node)
      return nil unless record[column] == node.id

      record[column] = nil
      record.save!
      record
    end

    def join_row(edge, from, to, attributes)
      return nil if rows(edge, from, to).exists?

      edge.model.create!(**hash_conditions(edge), **attributes,
                           edge.source_column => from.id, edge.target_column => to.id)
    end

    def rows(edge, from, to)
      edge.model.where(edge.source_column => from.id, edge.target_column => to.id).where(hash_conditions(edge))
    end

    def hash_conditions(edge) = edge.conditions.grep(Hash).reduce({}, :merge)
  end
end
