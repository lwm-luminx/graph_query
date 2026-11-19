# typed: strong
# frozen_string_literal: true

# Sorbet signatures for graph_query's public API. Tapioca picks up a gem's rbi/ folder on `tapioca gem`.
module GraphQuery
  VERSION = T.let(T.unsafe(nil), String)

  class Error < StandardError; end
  class NoEdges < Error; end
  class AmbiguousResult < Error; end
  class PatternError < Error; end
  class UnsupportedCypher < Error; end

  Scope = T.type_alias { T.any(ActiveRecord::Relation, ActiveRecord::Base, T.class_of(ActiveRecord::Base)) }
  ModelRef = T.type_alias { T.any(T.class_of(ActiveRecord::Base), String, Symbol) }
  EdgeCondition = T.type_alias { T.any(T::Hash[T.untyped, T.untyped], T.proc.returns(T.untyped)) }
  Names = T.type_alias { T.nilable(T.any(Symbol, T::Array[Symbol])) }
  NodePair = T.type_alias { [String, T.untyped] }
  ComputedEdge = T.type_alias { T.proc.returns(T.any(ActiveRecord::Relation, String)) }

  class StartSet
    sig { returns(String) }
    def sql; end

    sig { returns(T::Array[String]) }
    def types; end

    sig { params(sql: String, types: T::Array[String]).void }
    def initialize(sql:, types:); end
  end

  class << self
    sig { returns(Integer) }
    def max_depth; end

    sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
    def max_depth=(value); end

    sig { returns(Registry) }
    def registry; end

    sig { params(scope: Scope).returns(Query) }
    def from(scope); end

    sig { params(pairs: T::Array[[ModelRef, T.untyped]]).returns(Query) }
    def from_pairs(pairs); end

    sig { params(query: Query).returns(Query) }
    def from_query(query); end

    sig { params(pattern: String, params: T::Hash[Symbol, T.untyped], bindings: T.untyped).returns(Match) }
    def match(pattern, params: {}, **bindings); end

    sig { params(query: String, params: T.untyped).returns(T.any(ActiveRecord::Relation, T::Array[T.untyped], Integer)) }
    def cypher(query, **params); end

    sig { params(block: T.proc.params(graph: Transaction).void).returns(Transaction) }
    def transaction(&block); end

    sig { params(relation: ActiveRecord::Relation).returns(StartSet) }
    def start_set(relation); end

    sig { params(scope: Scope).returns(ActiveRecord::Relation) }
    def relation_for(scope); end

    sig { params(thing: T.any(Scope, String, Symbol)).returns(String) }
    def type_name(thing); end

    sig { params(thing: ModelRef).returns(T.class_of(ActiveRecord::Base)) }
    def model_for(thing); end
  end

  # Added to every Active Record model.
  module Model
    extend ActiveSupport::Concern

    mixes_in_class_methods(ClassMethods)

    module ClassMethods
      sig do
        params(
          name: Symbol,
          association: T.nilable(Symbol),
          to: T.nilable(ModelRef),
          through: T.nilable(ModelRef),
          source: T.nilable(T.any(String, Symbol)),
          target: T.nilable(T.any(String, Symbol)),
          sql: T.nilable(String),
          where: T.nilable(EdgeCondition),
          computed: T.nilable(ComputedEdge),
          block: T.nilable(T.proc.returns(T.any(ActiveRecord::Relation, String)))
        ).void
      end
      def graph_edge(name, association: nil, to: nil, through: nil, source: nil, target: nil, sql: nil, where: nil,
                     computed: nil, &block); end

      sig do
        params(
          name: T.nilable(Symbol),
          arguments: T::Hash[Symbol, T.untyped],
          returns: T.untyped,
          description: T.nilable(String)
        ).returns(T.nilable(Symbol))
      end
      def graph_mutation(name = nil, arguments: {}, returns: nil, description: nil); end

      sig { returns(T::Hash[Symbol, Mutation]) }
      def graph_mutations; end

      sig { params(names: Names, options: T.untyped).returns(Query) }
      def traverse(names = nil, **options); end

      sig { returns(Query) }
      def graph; end

      sig { params(pattern: String, params: T::Hash[Symbol, T.untyped], bindings: T.untyped).returns(Match) }
      def graph_match(pattern, params: {}, **bindings); end
    end

    sig { params(names: Names, options: T.untyped).returns(Query) }
    def traverse(names = nil, **options); end

    sig { returns(Query) }
    def graph; end
  end

  class Edge
    sig { returns(Symbol) }
    def name; end

    sig { returns(String) }
    def from; end

    sig { returns(String) }
    def to; end

    sig { returns(String) }
    def declared_by; end

    sig { returns(T.nilable(String)) }
    def table_model; end

    sig { returns(T.nilable(String)) }
    def sql; end

    sig { returns(T.nilable(T.class_of(ActiveRecord::Base))) }
    def model; end

    sig { params(edge_where: T.nilable(EdgeCondition)).returns(T::Boolean) }
    def filterable_by?(edge_where); end
  end

  class Registry
    sig { returns(T::Array[Edge]) }
    def all; end

    sig { params(declared_by: String).void }
    def clear(declared_by); end
  end

  class Query
    include Enumerable
    extend T::Generic

    Elem = type_member { { fixed: ActiveRecord::Base } }

    sig { returns(StartSet) }
    def start; end

    sig do
      params(
        names: Names,
        depth: T.any(Integer, T::Range[T.nilable(Integer)]),
        direction: Symbol,
        to: T.nilable(T.any(ModelRef, T::Array[ModelRef])),
        where: T.untyped,
        through: T.untyped,
        edge_where: T.nilable(EdgeCondition)
      ).returns(Query)
    end
    def traverse(names = nil, depth: 1, direction: :out, to: nil, where: nil, through: nil, edge_where: nil); end

    sig { params(names: Names, options: T.untyped).returns(Query) }
    def out(names = nil, **options); end

    sig { params(names: Names, options: T.untyped).returns(Query) }
    def inbound(names = nil, **options); end

    sig { params(names: Names, options: T.untyped).returns(Query) }
    def both(names = nil, **options); end

    sig { returns(T::Array[String]) }
    def types; end

    sig { params(origin: T::Boolean, depth: T::Boolean, path: T::Boolean).returns(String) }
    def to_sql(origin: false, depth: false, path: false); end

    sig { params(model: T.nilable(ModelRef)).returns(ActiveRecord::Relation) }
    def to_relation(model = nil); end

    sig { params(model: T.nilable(ModelRef)).returns(ActiveRecord::Relation) }
    def nodes(model = nil); end

    sig { params(model: T.nilable(ModelRef)).returns(ActiveRecord::Relation) }
    def with_depth(model = nil); end

    sig { returns(T::Array[NodePair]) }
    def pairs; end

    sig { returns(T::Array[ActiveRecord::Base]) }
    def records; end

    sig { params(model: T.nilable(ModelRef)).returns(T::Hash[T.untyped, T::Array[ActiveRecord::Base]]) }
    def by_origin(model = nil); end

    sig { params(model: T.nilable(ModelRef)).returns(T::Array[[T.untyped, T.untyped]]) }
    def origin_pairs(model = nil); end

    sig { returns(T::Array[T::Array[NodePair]]) }
    def paths; end

    sig { params(scope: ActiveRecord::Relation, name: T.any(Symbol, String)).returns(ActiveRecord::Relation) }
    def polymorphic(scope, name); end

    sig { override.params(block: T.proc.params(record: ActiveRecord::Base).void).void }
    def each(&block); end
  end

  class Pattern
    sig { params(source: String, params: T::Hash[Symbol, T.untyped]).returns(Pattern) }
    def self.parse(source, params = {}); end

    sig { returns(T::Hash[Symbol, [Symbol, Integer]]) }
    def variables; end
  end

  class Match
    sig { returns(Pattern) }
    def pattern; end

    sig { params(upto: Integer).returns(Query) }
    def query(upto = T.unsafe(nil)); end

    sig { params(var: T.nilable(Symbol), model: T.nilable(ModelRef)).returns(ActiveRecord::Relation) }
    def nodes(var = nil, model: nil); end

    sig { returns(T::Array[T::Array[NodePair]]) }
    def paths; end

    sig { params(model: T.nilable(ModelRef)).returns(ActiveRecord::Relation) }
    def to_relation(model = nil); end
  end

  class Cypher
    sig { params(source: String, params: T::Hash[T.any(Symbol, String), T.untyped]).void }
    def initialize(source, params = {}); end

    sig { returns(T.any(ActiveRecord::Relation, T::Array[T.untyped], Integer)) }
    def result; end

    sig { params(var: Symbol).returns(ActiveRecord::Relation) }
    def nodes(var); end
  end

  class Transaction
    class Change < Data
      sig { returns(Symbol) }
      def action; end

      sig { returns(T.nilable(Edge)) }
      def edge; end

      sig { returns(T.nilable(ActiveRecord::Base)) }
      def from; end

      sig { returns(T.nilable(ActiveRecord::Base)) }
      def to; end

      sig { returns(T.nilable(ActiveRecord::Base)) }
      def record; end
    end

    sig { returns(T::Array[Change]) }
    def changes; end

    sig do
      params(from: ActiveRecord::Base, name: Symbol, to: ActiveRecord::Base, via: T.nilable(ModelRef),
             attributes: T::Hash[Symbol, T.untyped]).returns(T.nilable(ActiveRecord::Base))
    end
    def link(from, name, to, via: nil, attributes: {}); end

    sig do
      params(from: ActiveRecord::Base, name: Symbol, to: ActiveRecord::Base, via: T.nilable(ModelRef))
        .returns(T.nilable(ActiveRecord::Base))
    end
    def unlink(from, name, to, via: nil); end

    sig do
      params(new_from: ActiveRecord::Base, name: Symbol, to: ActiveRecord::Base, from: T.nilable(ActiveRecord::Base),
             via: T.nilable(ModelRef), attributes: T::Hash[Symbol, T.untyped]).returns(T.nilable(ActiveRecord::Base))
    end
    def relink(new_from, name, to, from:, via: nil, attributes: {}); end

    sig { params(from: ActiveRecord::Base, name: Symbol, to: ActiveRecord::Base, via: T.nilable(ModelRef)).returns(T::Boolean) }
    def linked?(from, name, to, via: nil); end

    sig { params(model: T.class_of(ActiveRecord::Base), attributes: T.untyped).returns(ActiveRecord::Base) }
    def create(model, **attributes); end

    sig { params(record: ActiveRecord::Base, attributes: T.untyped).returns(ActiveRecord::Base) }
    def update(record, **attributes); end

    sig { params(record: ActiveRecord::Base).returns(ActiveRecord::Base) }
    def destroy(record); end
  end

  class Mutation
    sig { returns(T.class_of(ActiveRecord::Base)) }
    def model; end

    sig { returns(Symbol) }
    def name; end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def arguments; end

    sig { returns(T.untyped) }
    def returns; end

    sig { returns(T.nilable(String)) }
    def description; end

    sig { returns(T::Array[Symbol]) }
    def required; end

    sig { returns(T::Array[Symbol]) }
    def keywords; end

    sig { returns(T::Boolean) }
    def takes_graph?; end

    sig { params(record: ActiveRecord::Base, args: T.untyped).returns(T.untyped) }
    def call(record, **args); end
  end

  module Age
    sig { params(connection: T.untyped).returns(T::Boolean) }
    def self.available?(connection = T.unsafe(nil)); end

    sig do
      params(graph: String, query: String, columns: T::Array[T.any(String, Symbol)], connection: T.untyped)
        .returns(T.untyped)
    end
    def self.cypher(graph, query, columns: T.unsafe(nil), connection: T.unsafe(nil)); end
  end
end
