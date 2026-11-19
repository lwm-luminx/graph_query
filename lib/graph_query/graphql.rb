# frozen_string_literal: true

require 'graphql'
require 'graph_query'

module GraphQuery
  # graphql-ruby support, loaded with require 'graph_query/graphql'.
  #
  # Fields backed by walks, batched through GraphQL::Dataloader so a list of 50 locales asking for their venues runs
  # one statement, not 50:
  #
  #   class Types::LocaleType < Types::BaseObject
  #     extend GraphQuery::GraphQL::Fields
  #
  #     graph_field :children, [Types::LocaleType], edge: :contains                          # one hop
  #     graph_field :venues, [Types::VenueType], edge: [:contains, :has_venue], depth: 0..   # see below
  #     graph_field :bars, Types::VenueType.connection_type,                                 # paginated
  #                 pattern: '()-[:contains*0..]->()-[:has_venue]->(v:Venue)',
  #                 scope: ->(venues, context) { venues.where(kind: 'bar').order(:name) }
  #     graph_edges Locale                     # a field for every edge Locale declares
  #   end
  #
  # And mutations that run in one transaction, with a GraphQuery::Transaction to write edges through:
  #
  #   class Mutations::MoveVenue < Types::BaseMutation
  #     include GraphQuery::GraphQL::TransactionalMutation
  #     argument :venue_id, ID; argument :locale_id, ID
  #     field :venue, Types::VenueType
  #
  #     def resolve(venue_id:, locale_id:)
  #       venue = Venue.find(venue_id)
  #       graph.relink(Locale.find(locale_id), :has_venue, venue, from: venue.locale)
  #       { venue: venue.reload }
  #     end
  #   end
  #
  #   GraphQuery::GraphQL.edge_mutation(Locale, :contains, Locale, graphql_name: 'AddSubLocale')   # link/unlink by ID
  module GraphQL
    class << self
      # Finds the GraphQL type for a model name ('Venue' -> Types::VenueType, else Types::Venue). Set your own.
      attr_writer :type_for

      # Defaults to the name "Types::<Model>Type", which graphql-ruby resolves lazily, so a type can name itself
      # (or a type not loaded yet) while its class body is still running. Return a type or a type name.
      def type_for = @type_for ||= ->(name) { "Types::#{name}Type" }

      # Turns a GraphQL ID into a record. Defaults to the schema's object_from_id, else Model.find.
      attr_writer :record_for

      def record_for
        @record_for ||= lambda do |model, id, context|
          schema = context&.schema
          found = schema.object_from_id(id, context) if schema.respond_to?(:object_from_id)
          found.is_a?(model) ? found : model.find(id)
        rescue ::GraphQL::RequiredImplementationMissingError, NotImplementedError
          model.find(id)
        end
      end

      # A mutation class that links (or unlinks) the edge name from a from_model record to a to_model record by ID.
      def edge_mutation(from_model, name, to_model, action: :link, via: nil, name_prefix: nil,
                        base: ::GraphQL::Schema::RelayClassicMutation, graphql_name: nil)
        graphql_name ||= "#{name_prefix}#{action.to_s.camelize}#{from_model.name}#{name.to_s.camelize}#{to_model.name}"
        EdgeMutation.build(from_model, name, to_model, action:, via:, base:, graphql_name:)
      end
    end

    # A field's walk: which nodes it reaches from its object.
    class Walk
      attr_reader :model_name

      def initialize(edge: nil, pattern: nil, traverse: {}, model: nil, &block)
        unless [edge, pattern, block].compact.one?
          raise ArgumentError, 'graph_field takes one of edge:, pattern: or a block'
        end

        @edge = edge
        @pattern = pattern
        @traverse = traverse
        @block = block
        @model_name = model && GraphQuery.type_name(model)
      end

      # The Query from start (a relation of the field's objects).
      def call(start)
        if @block then @block.call(GraphQuery.from(start))
        elsif @pattern then GraphQuery.match(@pattern, __start: start).query
        else
          Array(@edge).each_with_index.reduce(GraphQuery.from(start)) do |query, (name, i)|
            # depth: and the other options apply to every step but the last, which takes one hop (has_venue after
            # contains*0..), unless the field names one edge.
            options = i == Array(@edge).size - 1 && Array(@edge).size > 1 ? @traverse.except(:depth) : @traverse
            query.traverse(name, **options)
          end
        end
      end

      def model_for(start) = (model_name || call(start).types.then { only(it) }).constantize

      private

      def only(types)
        return types.first if types.one?

        raise AmbiguousResult, "this field reaches #{types.join(', ')}: give graph_field model:"
      end
    end

    # Loads every object's nodes for one field in one query.
    class Source < ::GraphQL::Dataloader::Source
      def initialize(walk, scope, context)
        super()
        @walk = walk
        @scope = scope
        @context = context
      end

      def fetch(records)
        found = records.group_by(&:class).each_with_object({}) do |(model, group), by_record|
          start = model.where(model.primary_key => group.map(&:id))
          target = @walk.model_for(start)
          pairs = @walk.call(start).origin_pairs(target)
          nodes = target.where(target.primary_key => pairs.map(&:last).uniq)
          nodes = @scope.call(nodes, @context) if @scope
          nodes = nodes.to_a
          by_origin = pairs.group_by(&:first).transform_values { |list| list.to_set(&:last) }
          group.each do |record|
            reached = by_origin.fetch(record.id, Set.new)
            by_record[record] = nodes.select { reached.include?(it.id) }
          end
        end
        records.map { found.fetch(it) }
      end
    end

    # Class methods for GraphQL object types: extend GraphQuery::GraphQL::Fields.
    module Fields
      TRAVERSE = %i[depth direction to through edge_where].freeze

      # A field whose value is the nodes a walk reaches from the object: edge: (a name, or several in a row),
      # pattern: (Cypher-style, the first node being the object) or a block given the start Query. depth:,
      # direction:, to:, through: and edge_where: go to the walk. scope: (relation, context) -> relation narrows,
      # orders or authorizes the nodes. model: names the model when the walk can reach several. A connection type
      # gives a paginated relation per object; a list type is batched for every object on the page.
      def graph_field(name, type, *, edge: nil, pattern: nil, scope: nil, model: nil, **options, &)
        walk = Walk.new(edge:, pattern:, traverse: options.slice(*TRAVERSE), model:, &)
        connection = type.is_a?(Class) && type < ::GraphQL::Types::Relay::BaseConnection
        field(name, type, *, null: false, **options.except(*TRAVERSE))
        define_method(name) do
          if connection
            start = object.class.where(object.class.primary_key => object.id)
            nodes = walk.call(start).to_relation(walk.model_for(start))
            scope ? scope.call(nodes, context) : nodes
          else
            dataloader.with(Source, walk, scope, context).load(object)
          end
        end
      end

      # A list field for every edge model declares (one hop out): named after the edge, or edge_model when the edge
      # reaches several models. only:/except: pick edges by name; type_for: maps a model name to its GraphQL type.
      def graph_edges(model, only: nil, except: [], type_for: GraphQuery::GraphQL.type_for, scope: nil)
        edges = GraphQuery.registry.walkable([model.polymorphic_name], nil, :out).map(&:first)
        edges.group_by(&:name).each do |name, list|
          next if (only && !Array(only).include?(name)) || Array(except).include?(name)

          targets = list.map(&:to).uniq
          targets.each do |target|
            field_name = targets.one? ? name : :"#{name}_#{target.underscore.tr('/', '_').pluralize}"
            description = "#{target} nodes this #{model.name} #{name.to_s.humanize(capitalize: false)}."
            graph_field(field_name, [type_for.call(target)], edge: name, to: target, model: target, scope:,
                                                             description:)
          end
        end
      end
    end

    # Runs a mutation's resolve in one database transaction and gives it graph, a GraphQuery::Transaction. Raising
    # rolls everything back; a validation failure or GraphQuery error becomes a GraphQL error (or, when the mutation
    # has an errors field, { errors: [...] }).
    module TransactionalMutation
      def graph = @graph || raise(Error, 'graph is only open during resolve')

      def resolve_with_support(**)
        result = nil
        GraphQuery.transaction do |graph|
          @graph = graph
          result = super
          raise ActiveRecord::Rollback if result.is_a?(Hash) && result[:errors].present?
        end
        result
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed, GraphQuery::Error => e
        raise ::GraphQL::ExecutionError, e.message unless self.class.fields.key?('errors')

        { errors: [e.message] }
      ensure
        @graph = nil
      end
    end

    # Class methods for the schema's mutation type: extend GraphQuery::GraphQL::MutationFields, then
    # graph_mutations Locale, Venue adds a field for each graph mutation those models declare (locale_adopt, ...).
    module MutationFields
      def graph_mutations(*models, only: nil, except: [], base: ::GraphQL::Schema::RelayClassicMutation)
        models.each do |model|
          model.graph_mutations.each_value do |mutation|
            next if (only && !Array(only).include?(mutation.name)) || Array(except).include?(mutation.name)

            klass = ModelMutation.build(mutation, base:)
            field(:"#{model.model_name.singular}_#{mutation.name}", mutation: klass)
          end
        end
      end
    end

    # Builds a GraphQL mutation for a model's graph mutation: id (the record it runs on) and the method's arguments in;
    # result (what it returns) and errors out.
    module ModelMutation
      SCALARS = {
        String => ::GraphQL::Types::String, Integer => ::GraphQL::Types::Int, Float => ::GraphQL::Types::Float,
        boolean: ::GraphQL::Types::Boolean, TrueClass => ::GraphQL::Types::Boolean, id: ::GraphQL::Types::ID,
        json: ::GraphQL::Types::JSON, Date => ::GraphQL::Types::ISO8601Date,
        Time => ::GraphQL::Types::ISO8601DateTime, DateTime => ::GraphQL::Types::ISO8601DateTime
      }.freeze

      module_function

      def build(mutation, base:)
        model = mutation.model
        type_for = GraphQuery::GraphQL.type_for
        loaders = {}
        result_type = result_type(mutation, type_for)
        Class.new(base) do
          include TransactionalMutation

          graphql_name("#{model.name.gsub('::', '')}#{mutation.name.to_s.camelize}")
          description(mutation.description) if mutation.description
          argument :id, ::GraphQL::Types::ID, required: true, description: "The #{model.name} to run on."
          mutation.keywords.each do |key|
            spec = mutation.arguments.fetch(key) do
              raise ArgumentError, "#{mutation.inspect}: give #{key} a type in arguments:"
            end
            graphql_name, graphql_type, loader = ModelMutation.argument(key, spec)
            loaders[graphql_name] = [key, loader]
            argument graphql_name, graphql_type, required: mutation.required.include?(key)
          end
          field :result, result_type, null: true
          field :errors, [::GraphQL::Types::String], null: false

          define_method(:resolve) do |id:, **inputs|
            record = GraphQuery::GraphQL.record_for.call(model, id, context)
            keywords = inputs.to_h do |graphql_name, value|
              key, loader = loaders.fetch(graphql_name)
              [key, loader ? loader.call(value, context) : value]
            end
            keywords[:graph] = graph if mutation.takes_graph?
            # Already inside this mutation's transaction: the method's own wrapper opens a savepoint in it.
            { result: mutation.call(record, **keywords), errors: [] }
          end
        end
      end

      # [GraphQL argument name, type, loader or nil] for one keyword.
      def argument(key, spec)
        list = spec.is_a?(Array)
        inner = list ? spec.first : spec
        inner = inner.constantize if inner.is_a?(String)
        return model_argument(key, inner, list) if inner.is_a?(Class) && inner < ActiveRecord::Base

        type = SCALARS.fetch(inner) { inner.is_a?(Class) && inner < ::GraphQL::Schema::Member ? inner : nil }
        raise ArgumentError, "can't map #{inner.inspect} to a GraphQL type for #{key}" unless type

        [key, list ? [type] : type, nil]
      end

      # A model keyword takes IDs (child: becomes childId, venues: becomes venueIds) loaded through record_for.
      def model_argument(key, model, list)
        name = list ? :"#{key.to_s.singularize}_ids" : :"#{key}_id"
        loader = lambda do |value, context|
          load = ->(id) { GraphQuery::GraphQL.record_for.call(model, id, context) }
          list ? value.map(&load) : load.call(value)
        end
        [name, list ? [::GraphQL::Types::ID] : ::GraphQL::Types::ID, loader]
      end

      def result_type(mutation, type_for)
        returns = mutation.returns || mutation.model
        returns = returns.constantize if returns.is_a?(String)
        return SCALARS.fetch(returns) if SCALARS.key?(returns)
        return returns if returns.is_a?(Class) && returns < ::GraphQL::Schema::Member

        type_for.call(GraphQuery.type_name(returns))
      end
    end

    # Builds link/unlink mutations for one edge (GraphQuery::GraphQL.edge_mutation).
    module EdgeMutation
      module_function

      def build(from_model, name, to_model, action:, via:, base:, graphql_name:)
        raise ArgumentError, "action must be :link or :unlink, not #{action.inspect}" unless %i[link
                                                                                                unlink].include?(action)

        type_for = GraphQuery::GraphQL.type_for
        Class.new(base) do
          include TransactionalMutation

          graphql_name(graphql_name)
          description("#{action.to_s.capitalize}s the #{name} edge from a #{from_model.name} to a #{to_model.name}.")
          argument :from_id, ::GraphQL::Types::ID, required: true
          argument :to_id, ::GraphQL::Types::ID, required: true
          field :from, type_for.call(from_model.name), null: true
          field :to, type_for.call(to_model.name), null: true
          field :changed, ::GraphQL::Types::Boolean, null: false
          field :errors, [::GraphQL::Types::String], null: false

          define_method(:resolve) do |from_id:, to_id:|
            record_for = GraphQuery::GraphQL.record_for
            from = record_for.call(from_model, from_id, context)
            to = record_for.call(to_model, to_id, context)
            before = graph.changes.size
            graph.public_send(action, from, name, to, via:)
            { from:, to:, changed: graph.changes.size > before, errors: [] }
          end
        end
      end
    end
  end
end
