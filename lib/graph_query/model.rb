# frozen_string_literal: true

module GraphQuery
  # What every Active Record model gets: graph_edge to declare edges, and traverse / graph_match to walk them from
  # the current scope (or from one record).
  module Model
    extend ActiveSupport::Concern

    class_methods do
      # Declares an edge named name leaving this model's nodes.
      #
      #   graph_edge :contains, association: :children                  # has_many: locales.parent_id
      #   graph_edge :within, association: :parent                      # belongs_to
      #   graph_edge :billed_on, association: :events                   # has_many :events, through: :event_people
      #   graph_edge :contains, to: 'Locale', through: 'LocaleGrouping', # a join model named outright
      #                         source: :super_locale_id, target: :member_locale_id
      #   graph_edge :near, to: 'Venue', sql: 'SELECT a_id AS source_id, b_id AS target_id FROM venue_pairs'
      #   graph_edge :near, to: 'Venue', computed: -> { VenuePair.where(active: true)             # built per query
      #                                                         .select('a_id AS source_id, b_id AS target_id') }
      #   graph_edge(:near, to: 'Venue') { VenuePair.select('a_id AS source_id, b_id AS target_id') }  # the same
      #
      # where: a Hash or a scope Proc (run on the edge's table) that rows must match, besides the association's own
      # scope. Several declarations with one name make one edge kind that unions them.
      def graph_edge(name, association: nil, to: nil, through: nil, source: nil, target: nil, sql: nil, where: nil,
                     computed: nil, &block)
        sql = computed || block || sql
        @graph_edges_declared ||= begin
          GraphQuery.registry.clear(self.name)
          true
        end
        key = [self.name, name, association, to, through, source, target, sql, where]
        GraphQuery.registry.add(key:, declared_by: self.name) do
          build_graph_edge(name, association:, to:, through:, source:, target:, sql:, where:)
        end
      end

      def build_graph_edge(name, association:, to:, through:, source:, target:, sql:, where:)
        if association
          reflection = reflect_on_association(association) || raise(ArgumentError,
                                                                    "#{self.name} has no association #{association}")
          Associations.edge_for(self, name, reflection, where:)
        elsif through
          Edge.new(name:, from: polymorphic_name, to: to || raise(ArgumentError, 'to: is required'),
                   declared_by: self.name, table_model: through, source_column: source || foreign_key,
                   target_column: target || raise(ArgumentError, 'target: is required'), conditions: [where])
        elsif sql
          Edge.new(name:, from: polymorphic_name, to: to || raise(ArgumentError, 'to: is required'),
                   declared_by: self.name, sql:)
        else
          raise ArgumentError, 'graph_edge needs association:, through: or sql:'
        end
      end

      # Declares a graph mutation (see GraphQuery::Mutation): graph_mutation def name(...) ... end, options decorates
      # that method; graph_mutation options alone decorates the next method defined.
      def graph_mutation(name = nil, arguments: {}, returns: nil, description: nil)
        options = { arguments:, returns:, description: }
        return @pending_graph_mutation = options if name.nil?

        mutation = Mutation.new(model: self, name:, **options)
        graph_mutations[mutation.name] = mutation
        Mutation::Wrapping.wrap(self, mutation.name)
        mutation.name
      end

      # This model's graph mutations, by name.
      def graph_mutations = @graph_mutations ||= {}

      def method_added(name)
        super
        options = @pending_graph_mutation or return
        @pending_graph_mutation = nil
        graph_mutation(name, **options)
      end

      # Walks edges from every node in the current scope (Locale.where(...).traverse(:contains, depth: 0..)).
      # Returns a Query, which acts as a relation of the nodes it reaches.
      def traverse(names = nil, **)
        Query.new(GraphQuery.start_set(all)).traverse(names, **)
      end

      # A Query starting from the current scope that walks nothing yet (chain .out / .inbound / .traverse).
      def graph = Query.new(GraphQuery.start_set(all))

      # A Cypher-style pattern whose first node is the current scope:
      #   Locale.where(slug: 'seattle').graph_match('(l)-[:contains*0..]->()-[:has_venue]->(v:Venue)')
      def graph_match(pattern, params: {}, **bindings)
        first = Pattern.parse(pattern, params).nodes.first
        GraphQuery.match(pattern, params:, **bindings, first.var || :__start => all)
      end
    end

    # The same walks, starting from this record alone.
    def traverse(names = nil, **) = self.class.where(id:).traverse(names, **)
    def graph = self.class.where(id:).graph
  end
end
