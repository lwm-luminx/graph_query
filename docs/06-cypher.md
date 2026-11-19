# Cypher queries

`GraphQuery.cypher(query, **params)` runs a read-only Cypher query on the same walker as `traverse`: no Apache AGE, no
extension, one `WITH RECURSIVE` per path.

```ruby
GraphQuery.cypher(<<~CYPHER, state: 'Washington', limit: 10)
  MATCH (s:Locale {name: $state})-[:contains*0..]->(c:Locale)-[:has_venue]->(v:Venue)
  WHERE c.kind = 'city' AND v.name STARTS WITH 'The' AND NOT v.closed
  RETURN v
  ORDER BY v.name
  LIMIT $limit
CYPHER
# => a Venue relation, still chainable
```

## Clauses

| Clause | Takes |
| --- | --- |
| `MATCH` | one or more [patterns](#patterns), comma-separated or in several `MATCH` clauses |
| `WHERE` | conditions on node properties (after any `MATCH`; several are ANDed) |
| `RETURN` | `v`, `v.name, v.kind` (with optional `AS`), `count(*)`, `count(v)`, `count(DISTINCT v)`; `DISTINCT` |
| `ORDER BY` | `v.name`, `toLower(v.name) DESC`, several |
| `SKIP`, `LIMIT` | a whole number or a `$param` |

Labels are model names; relationship types are edge names (`HAS_VENUE` and `hasVenue` both match `:has_venue`).
Properties are the model's columns. Keywords are case-insensitive, `//` starts a comment, and a trailing `;` is fine.

## WHERE

| Condition | SQL |
| --- | --- |
| `v.x = 1`, `<>`, `!=`, `<`, `<=`, `>`, `>=` | comparisons (`= null` is `IS NULL`) |
| `v.x IS NULL`, `v.x IS NOT NULL` | null tests |
| `v.x IN ['a', 'b']`, `v.x NOT IN $list` | `IN` |
| `v.x STARTS WITH 'a'`, `ENDS WITH`, `CONTAINS` | `LIKE`, with `%` and `_` escaped |
| `v.x =~ 'Sea.*'` | a PostgreSQL regular expression on the whole value |
| `toLower(v.x) = 'bar'`, `toUpper(...)` | `LOWER()` / `UPPER()` |
| `v.open` | `v.open = true` |
| `v.x = v.y` | two columns of the same node |
| `AND`, `OR`, `XOR`, `NOT`, `( ... )` | as written |

Each condition is about **one variable**. graph_query turns each variable's conditions into a relation and walks
through it, so conditions on nodes in the middle of a path narrow the walk as it goes:

```cypher
MATCH (s:Locale)-[:contains*0..]->(c:Locale)-[:has_venue]->(v:Venue)
WHERE s.name = 'USA' AND c.kind = 'city' AND (v.name STARTS WITH 'E' OR v.name ENDS WITH 'sh')
RETURN v
```

A condition comparing two variables (`a.name = b.name`) raises `GraphQuery::UnsupportedCypher`.

## RETURN

| RETURN | Gives |
| --- | --- |
| `v` | a relation of `v`'s nodes (lazy, chainable) |
| `v.name` | `pluck(:name)`: `['Eagle', 'Globe']` |
| `v.name, v.kind` | `pluck(:name, :kind)`: `[['Eagle', 'bar'], ...]` |
| `DISTINCT v.kind` | distinct values |
| `count(*)`, `count(v)`, `count(DISTINCT v)` | an Integer: how many distinct nodes |

Return one variable. A walk finds the nodes that can be reached, not every combination of nodes along the way, so
`RETURN a, b` raises `UnsupportedCypher`; return one and walk again from it if you need the other.

## Several patterns

Patterns that share a variable are joined on it:

```cypher
MATCH (p:Person)-[:billed_on]->(e:Event), (v:Venue)-[:hosts]->(e)
MATCH (:Locale {name: 'Oregon'})-[:contains*0..]->()-[:has_venue]->(v)
RETURN e
```

Each pattern narrows the shared variables to the nodes it can match, and the narrowing repeats once per pattern so it
carries through chains of patterns. This is exact when the patterns form a tree (joined one variable at a time). When
two patterns share two variables, each variable is narrowed on its own, so a pair that matches separately but not
together still passes.

## Parameters

`$name` reads the keyword arguments: in property maps, `WHERE`, `IN`, `SKIP` and `LIMIT`. Values are always passed to
SQL as quoted values, never as SQL text. A missing parameter raises `GraphQuery::PatternError`.

## Not supported

Writing clauses (`CREATE`, `MERGE`, `SET`, `DELETE`), `OPTIONAL MATCH`, `WITH`, `UNWIND`, `UNION`, aggregation other
than `count`, path variables (`p = (a)-->(b)`), and returning several variables. Each raises a `PatternError` or
`UnsupportedCypher` that names what it met.

If a database has Apache AGE, `GraphQuery::Age.cypher` passes full Cypher through to it (see [How it runs](#internals)).
