# Changelog

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
