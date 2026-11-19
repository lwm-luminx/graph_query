# frozen_string_literal: true

module GraphQuery
  # A model method declared as a graph mutation: it runs in a GraphQuery.transaction, and it carries what a GraphQL
  # mutation needs to expose it (arguments and their types, what it returns, a description).
  #
  #   class Locale < ApplicationRecord
  #     graph_mutation def adopt(child:, role: nil, graph:)            # decorates the method defined here
  #       graph.link(self, :contains, child)
  #       graph.link(child, :tagged, Tag.find_by!(name: role)) if role
  #       self
  #     end, arguments: { child: Locale, role: String }, description: 'Files a locale under this one.'
  #
  #     graph_mutation arguments: { venue: Venue }, returns: Venue      # or decorates the next method defined
  #     def take_venue(venue:, graph:) = graph.relink(self, :has_venue, venue, from: venue.locale) && venue
  #   end
  #
  #   seattle.adopt(child: hill)       # in a transaction: any error rolls every write back
  #
  # A graph: keyword parameter receives the GraphQuery::Transaction. Keyword parameters without a default are
  # required arguments. Argument types: String, Integer, Float, :boolean, :id, :json, Date, Time, a model (passed as
  # an ID, loaded into a record; a model name String works too, for models not loaded yet), [Model] (IDs, loaded),
  # or a GraphQL type. GraphQuery::GraphQL exposes them as
  # GraphQL mutations (graph_mutations Locale).
  class Mutation
    attr_reader :model, :name, :arguments, :returns, :description

    def initialize(model:, name:, arguments:, returns:, description:)
      @model = model
      @name = name.to_sym
      @arguments = arguments.transform_keys(&:to_sym)
      @returns = returns
      @description = description
    end

    # Argument names the method requires (keyword parameters without a default), graph: aside.
    def required
      parameters.filter_map { |kind, arg| arg if kind == :keyreq && arg != :graph }
    end

    # Every keyword the method takes, graph: aside.
    def keywords = parameters.filter_map { |kind, arg| arg if %i[key keyreq].include?(kind) && arg != :graph }

    def takes_graph? = parameters.any? { |kind, arg| %i[key keyreq].include?(kind) && arg == :graph }

    def inspect = "#<GraphQuery::Mutation #{model.name}##{name}>"

    # Runs the method on record with keyword arguments, in a transaction.
    def call(record, **arguments) = record.public_send(name, **arguments)

    private

    # The decorated method's parameters (past the transaction wrapper).
    def parameters
      method = model.instance_method(name)
      method = method.super_method if method.owner == model.instance_variable_get(:@graph_mutation_wrapper)
      method.parameters
    end

    # The module each model prepends to run its graph mutations in transactions.
    module Wrapping
      module_function

      def wrap(model, name)
        wrapper = model.instance_variable_get(:@graph_mutation_wrapper) ||
                  Module.new.tap do |mod|
                    model.instance_variable_set(:@graph_mutation_wrapper, mod)
                    model.prepend(mod)
                  end
        mutation = model.graph_mutations.fetch(name)
        wrapper.define_method(name) do |*args, **kwargs, &block|
          result = nil
          GraphQuery.transaction do |graph|
            kwargs = kwargs.merge(graph:) if mutation.takes_graph? && !kwargs.key?(:graph)
            result = super(*args, **kwargs, &block)
          end
          result
        end
      end
    end
  end
end
