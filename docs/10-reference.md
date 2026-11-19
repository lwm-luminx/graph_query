# Reference

## On every model

| Method | |
| --- | --- |
| `graph_edge(name, association:)` | an edge from an association |
| `graph_edge(name, to:, through:, source:, target:)` | an edge from a join model's columns |
| `graph_edge(name, to:, sql:)` | an edge from SQL selecting `source_id`, `target_id` |
| `graph_edge(name, to:, computed: -> { ... })`, `graph_edge(name, to:) { ... }` | an edge from a relation or SQL built per query |
| ... `where:` | a Hash or scope Proc the edge's rows must match |
| `Model.traverse(names = nil, **options)` | a Query from the current scope |
| `Model.graph` | a Query from the current scope, no steps yet |
| `Model.graph_match(pattern, params: {}, **bindings)` | a Match whose first node is the current scope |
| `record.traverse(...)`, `record.graph` | the same from one record |
| `graph_mutation(name = nil, arguments: {}, returns: nil, description: nil)` | mark a method as a [graph mutation](#writes) |
| `Model.graph_mutations` | the model's graph mutations, by name |

`to:`, `through:` and `via:` take a model class or its name.

## GraphQuery

| Method | |
| --- | --- |
| `GraphQuery.from(scope)` | a Query from a relation, record or model |
| `GraphQuery.from_pairs(pairs)` | a Query from `[[type, id], ...]` of any models |
| `GraphQuery.from_query(query)` | a Query from the nodes another one reaches |
| `GraphQuery.match(pattern, params: {}, **bindings)` | a Match |
| `GraphQuery.cypher(query, **params)` | a relation, pluck rows or a count (see [Cypher queries](#cypher)) |
| `GraphQuery.transaction { \|graph\| ... }` | a [Transaction](#writes) in one database transaction |
| `GraphQuery.max_depth`, `max_depth=` | the hop cap for counted unbounded steps (32) |
| `GraphQuery.registry.all` | every declared edge |

## GraphQuery::Query

| Method | |
| --- | --- |
| `traverse(names = nil, depth: 1, direction: :out, to: nil, where: nil, through: nil, edge_where: nil)` | add a step |
| `out(names, **)`, `inbound(names, **)`, `both(names, **)` | a step with the direction fixed |
| `types` | model names the walk can end on |
| `to_relation(model = nil)`, `nodes` | reached nodes as a relation |
| `with_depth(model = nil)` | that relation with `graph_depth` |
| `pairs`, `records` | every reached node, any model |
| `by_origin(model = nil)`, `origin_pairs(model = nil)` | reached nodes grouped by start node |
| `polymorphic(scope, name)` | rows of scope whose polymorphic `name` points at a reached node |
| `paths` | every simple path |
| `to_sql(origin: false, depth: false, path: false)` | the statement |
| relation methods | delegated to `to_relation` when the walk reaches one model |

## GraphQuery::Match

| Method | |
| --- | --- |
| `nodes(var = nil, model: nil)` | a node variable's matches (default: the last node) |
| `paths` | every full match's path |
| `query(upto = all)` | the Query for the pattern (up to a node index) |
| relation methods | delegated to `nodes` |

## GraphQuery::Cypher

| Method | |
| --- | --- |
| `Cypher.new(query, params = {})` | parse a query (raises on bad syntax) |
| `result` | what `GraphQuery.cypher` returns |
| `nodes(:var)` | any node variable's matches, as a relation |
| `patterns`, `items`, `orders`, `skip`, `limit`, `distinct` | the parsed query |

## GraphQuery::Transaction

| Method | |
| --- | --- |
| `link(from, name, to, via: nil, attributes: {})` | add an edge (the written record, or nil if it was already there) |
| `unlink(from, name, to, via: nil)` | remove an edge |
| `relink(new_from, name, to, from:, via: nil, attributes: {})` | move an edge to a new source |
| `linked?(from, name, to, via: nil)` | whether an edge is there |
| `create`, `update`, `destroy` | write nodes |
| `changes` | every write, in order |

## GraphQuery::GraphQL

Loaded with `require 'graph_query/graphql'`.

| Method | |
| --- | --- |
| `Fields#graph_field(name, type, edge: \| pattern: \| &block, scope:, model:, depth:, ...)` | a field backed by a walk, batched |
| `Fields#graph_edges(model, only:, except:, scope:, type_for:)` | a field per declared edge |
| `MutationFields#graph_mutations(*models, only:, except:, base:)` | a mutation field per graph mutation |
| `TransactionalMutation` | include in a mutation: `resolve` runs in a transaction with `graph` |
| `GraphQuery::GraphQL.edge_mutation(from_model, name, to_model, action: :link, via:, graphql_name:, base:)` | a mutation that links or unlinks one edge by ID |
| `GraphQuery::GraphQL.type_for`, `type_for=` | model name to GraphQL type (default `"Types::<Model>Type"`) |
| `GraphQuery::GraphQL.record_for`, `record_for=` | `(model, id, context)` to a record |

## Errors

All inherit from `GraphQuery::Error`.

| Error | When |
| --- | --- |
| `GraphQuery::NoEdges` | a step names edges that don't leave its nodes, or can never reach its `to:` |
| `GraphQuery::AmbiguousResult` | a relation was asked of a walk that reaches several models |
| `GraphQuery::PatternError` | a pattern or query can't be read, binds an unknown variable, misses a `$param`, or has an unbound, unlabelled first node |
| `GraphQuery::UnsupportedCypher` | Cypher that reads fine but asks for what graph_query doesn't do (two variables in one condition, `RETURN a, b`, `OPTIONAL MATCH`) |

## Types

The gem ships signatures for both type checkers:

- **RBS** in `sig/graph_query.rbs`. Steep and other RBS tools find it in the installed gem; Active Record's own types
  come from [gem_rbs_collection](https://github.com/ruby/gem_rbs_collection) (`rbs collection install`).
- **Sorbet** in `rbi/graph_query.rbi`. `bin/tapioca gem graph_query` copies it into `sorbet/rbi/gems`.

Both describe `graph_edge`, `graph_mutation`, `traverse`, `graph` and `graph_match` on every model, and `Query`,
`Match`, `Cypher`, `Pattern`, `Edge`, `Transaction`, `Mutation` and the errors. The GraphQL module isn't typed:
graphql-ruby's class DSL has no signatures to build on.
