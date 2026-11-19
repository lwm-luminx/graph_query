# Changelog

## 0.2.0 (2026-11-19)

- Computed edges: `graph_edge name, to:, computed: -> { ... }` (or a block) returns a relation or SQL, built each
  time a query runs and compiled into the same single statement.
- `GraphQuery.transaction` writes through declared edges: `link`, `unlink`, `relink`, `linked?`, plus `create`,
  `update` and `destroy`, in one database transaction. Foreign keys are set or cleared, and join rows created or
  destroyed, wherever the edge is kept.
- `graph_mutation` marks a model method as a graph mutation: it runs in a transaction, is handed the graph, and
  carries the argument and result types GraphQL needs.
- `require 'graph_query/graphql'` for graphql-ruby: `graph_field` (by edge, pattern or block; batched through
  `GraphQL::Dataloader`; connections paginate in SQL), `graph_edges` (a field per declared edge), `graph_mutations`
  (a mutation field per graph mutation), `TransactionalMutation` and `edge_mutation`.
- `to:`, `through:` and `via:` take model classes as well as names.
- RBS and RBI signatures for the above.

## 0.1.0 (2026-11-19)

First release.

- `graph_edge` on Active Record models: edges from `belongs_to`, `has_many`/`has_one` and `has_many :through`
  associations, from a join model named outright, or from SQL. Same-named declarations union.
- `traverse` walks with `depth:` (Integer or Range, unbounded allowed), `direction:` (`:out`, `:in`, `:both`), `to:`,
  `where:`, `through:` and `edge_where:`; one `WITH RECURSIVE` statement per walk, edges joined through
  `CROSS JOIN LATERAL`.
- Results as relations, plus `with_depth`, `pairs`, `records`, `polymorphic`, `by_origin`, `origin_pairs`, `paths` and
  `to_sql`.
- `GraphQuery.match` for linear Cypher-style patterns with bound variables and property maps.
- `GraphQuery.cypher` for read-only Cypher: `MATCH` (several paths joined on shared variables), `WHERE`, `RETURN`,
  `ORDER BY`, `SKIP`, `LIMIT` and `$params`.
- RBS signatures (`sig/`) and a Sorbet RBI (`rbi/`).
- `GraphQuery::Age`, a pass-through to Apache AGE where a database has it.
