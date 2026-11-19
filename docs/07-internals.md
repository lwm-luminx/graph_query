# How it runs

## One statement per walk

Each walk compiles to one `WITH RECURSIVE` statement. Node sets are CTEs: `g0` is the start, `gN` the nodes after step
N, each with columns `(node_type, node_id)` plus whatever the result needs (`origin_type`/`origin_id`, `depth`, `path`).

This walk:

```ruby
Locale.where(name: 'Seattle').traverse(:contains, depth: 0..).traverse(:features)
```

compiles to (reformatted):

```sql
WITH RECURSIVE
g0 AS (
  SELECT DISTINCT node_type, node_id FROM (
    SELECT 'Locale'::text AS node_type, start_rows."id" AS node_id
    FROM (SELECT "locales"."id" FROM "locales" WHERE "locales"."name" = 'Seattle') start_rows
  ) graph_query_start),
g1_walk(node_type, node_id) AS (
  SELECT p.node_type, p.node_id FROM g0 p
  UNION
  SELECT e.to_type, e.to_id FROM g1_walk w
  CROSS JOIN LATERAL (
    (SELECT 'Locale'::text AS from_type, edge_rows.source_id AS from_id,
            'Locale'::text AS to_type,   edge_rows.target_id AS to_id
     FROM (SELECT parent_id AS source_id, id AS target_id FROM locales
           WHERE parent_id IS NOT NULL AND id IS NOT NULL) edge_rows
     WHERE edge_rows.source_id = w.node_id AND w.node_type = 'Locale')
    UNION ALL
    (SELECT 'Locale', edge_rows.source_id, 'Locale', edge_rows.target_id
     FROM (SELECT super_locale_id AS source_id, member_locale_id AS target_id FROM locale_groupings
           WHERE super_locale_id IS NOT NULL AND member_locale_id IS NOT NULL) edge_rows
     WHERE edge_rows.source_id = w.node_id AND w.node_type = 'Locale')
  ) e),
g1(node_type, node_id) AS (SELECT DISTINCT * FROM g1_walk x),
g2(node_type, node_id) AS (
  SELECT DISTINCT * FROM (
    SELECT e.to_type, e.to_id FROM g1 p
    CROSS JOIN LATERAL (
      (SELECT 'Locale', edge_rows.source_id, 'Person', edge_rows.target_id
       FROM (SELECT locale_id AS source_id, person_id AS target_id FROM person_locales
             WHERE locale_id IS NOT NULL AND person_id IS NOT NULL) edge_rows
       WHERE edge_rows.source_id = p.node_id AND p.node_type = 'Locale')
    ) e) x)
SELECT * FROM g2
```

## Step shapes

The compiler picks the cheapest shape a step allows:

| Step | Shape |
| --- | --- |
| no edge to follow, `depth: 0..` | keep the nodes it started on |
| `depth: 1` or `0..1` | one join |
| `depth: 1..` or `0..` | a recursive set with `UNION`: it ends when nothing new turns up, so cycles end it |
| `depth: 1..3`, `2..`, or anything needing `with_depth` | a hop count on each row, stopping at the bound (or `max_depth`), then grouped to the fewest hops |
| `paths` | `UNION ALL` of routes, each carrying a `text[]` of `'Type:id'` and refusing to revisit a node |

## Why LATERAL

Each hop joins the edges through `CROSS JOIN LATERAL`, with the `source_id = node_id` condition inside each branch of
the edge union. That lets PostgreSQL read each edge table through its index on the column that points back, one row
of the frontier at a time, instead of scanning and hashing whole tables on every iteration. On a 200,000-locale tree, a
subtree walk went from 62 ms to 8 ms with this change. Index the foreign key columns your edges read (Rails does for
`references`).

## Which edges a step uses

Before compiling, a step works out which edges it may follow: those leaving the models it starts on and, for a
multi-hop step, those leaving every model it can reach, until no new model turns up. A step over `:rolls_up` from a
Locale therefore also follows Venue's and EventSeries' `:rolls_up` edges. Only those edges' tables appear in the SQL.

## Limits

- **Node ids share a type** within a walk (all uuid, or all bigint).
- **`max_depth`** (32) caps unbounded steps that count hops. Plain closures (`0..`, `1..`) have no cap; cycles end them.
- **`paths`** grows with the number of routes, not nodes.
- **No branching patterns.** Chain steps or start a second walk with `from_query`.
- **SQL edges** don't take `edge_where:`, and only use indexes if the planner can push the condition into them.

## Apache AGE

Where a database has Apache AGE, `GraphQuery::Age` passes real Cypher through:

```ruby
GraphQuery::Age.available?   # => false on Heroku Postgres
GraphQuery::Age.cypher('my_graph', 'MATCH (a)-[:KNOWS]->(b) RETURN a, b', columns: %w[a b])
```

It's a pass-through for databases that have it, not a second engine: AudienceKit uses the CTE walker only.

## Tests

The behaviour is written as shared examples (`spec/support/graph_query_examples.rb`) over a small graph in `gq_`
tables. The API runs them in `spec/graph_query`; to run them on their own from the app's root:

```sh
GRAPH_QUERY_DATABASE_URL=postgres:///graph_query_test bundle exec rspec -O /dev/null engines/graph_query/spec
```
