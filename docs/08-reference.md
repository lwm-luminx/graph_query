# Reference

## On every model

| Method | |
| --- | --- |
| `graph_edge(name, association:)` | an edge from an association |
| `graph_edge(name, to:, through:, source:, target:)` | an edge from a join model's columns |
| `graph_edge(name, to:, sql:)` | an edge from SQL selecting `source_id`, `target_id` |
| ... `where:` | a Hash or scope Proc the edge's rows must match |
| `Model.traverse(names = nil, **options)` | a Query from the current scope |
| `Model.graph` | a Query from the current scope, no steps yet |
| `Model.graph_match(pattern, params: {}, **bindings)` | a Match whose first node is the current scope |
| `record.traverse(...)`, `record.graph` | the same from one record |

## GraphQuery

| Method | |
| --- | --- |
| `GraphQuery.from(scope)` | a Query from a relation, record or model |
| `GraphQuery.from_pairs(pairs)` | a Query from `[[type, id], ...]` of any models |
| `GraphQuery.from_query(query)` | a Query from the nodes another one reaches |
| `GraphQuery.match(pattern, params: {}, **bindings)` | a Match |
| `GraphQuery.cypher(query, **params)` | a relation, pluck rows or a count (see [Cypher queries](#cypher)) |
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

Both describe `graph_edge`, `traverse`, `graph` and `graph_match` on every model, and `Query`, `Match`, `Cypher`,
`Pattern`, `Edge` and the errors.
