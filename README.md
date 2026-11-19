# graph_query

Graph traversals for Active Record on PostgreSQL. Declare edges on your models from the associations they already
have; walk them with recursive CTEs in a Ruby chain or a Cypher-style pattern; get Active Record relations back. It
needs nothing installed in the database (no Apache AGE, no extension), so it runs on Heroku Postgres.

```ruby
class Locale < ApplicationRecord
  has_many :children, class_name: 'Locale', foreign_key: :parent_id
  has_many :venues

  graph_edge :contains, association: :children
  graph_edge :contains, to: 'Locale', through: 'LocaleGrouping', source: :super_locale_id, target: :member_locale_id
  graph_edge :has_venue, association: :venues
end

class Venue < ApplicationRecord
  graph_edge :hosts, association: :all_events
end

washington = Locale.where(slug: 'washington')
washington.traverse(:contains, depth: 0..)                              # the state and everything in it
washington.traverse(:contains, depth: 0..).traverse(:has_venue)         # every venue in the state
  .where(kind: 'bar').order(:name)                                      # ... still a relation
seattle.traverse(:contains, direction: :in, depth: 1..)                 # everything Seattle lies within

GraphQuery.match('(s:Locale)-[:contains*0..]->()-[:has_venue]->(v:Venue)-[:hosts]->(e:Event)<-[:billed_on]-(p:Person)',
                 s: washington, e: Event.upcoming).nodes(:v)            # venues where someone billed upcoming plays
```

## Declaring edges

`graph_edge name, ...` on the model the edge leaves. Several declarations with one name make one kind of edge that
unions them (a locale contains its children and, for a super locale, the locales it groups).

| Declaration | Rows that are edges |
| --- | --- |
| `association: :children` (has_many / has_one) | the target's rows, pointing back with the foreign key; the association's scope applies; `as:` checks the type column |
| `association: :parent` (belongs_to) | the owner's rows with the foreign key set |
| `association: :events` (has_many :through a join model that belongs_to the target) | the join model's rows |
| `to: 'Locale', through: 'LocaleGrouping', source: :super_locale_id, target: :member_locale_id` | a join model named outright |
| `to: 'Venue', sql: 'SELECT a_id AS source_id, b_id AS target_id FROM ...'` | any SQL |

`where:` adds a Hash or scope Proc the edge's rows must match. Edges are built the first time a query needs them, so
declarations can name models that aren't loaded yet, and reloading a model replaces its edges.

## Walking

`Model.traverse(names, ...)` (on a scope, or `record.traverse`) and `query.traverse(...)` to chain steps:

- `names`: a Symbol, an Array of them, or nil for every edge.
- `depth:` an Integer or Range: `1` (default), `2`, `1..3`, `0..` (the start nodes too), `1..`.
- `direction:` `:out` (default), `:in` (walk edges backwards: ancestors, who hosts this), `:both`.
- `to:` only arrive at these models. `where:` only arrive at nodes in this relation (one per model; a Hash filters
  the one model the step reaches). `through:` every node passed through must be in this relation (Cypher's
  `all(n IN nodes(p) WHERE ...)`). `edge_where:` a Hash the edge's row must match (edges kept somewhere without those
  columns don't match, like a missing property in Cypher).

`graph.out(:x)`, `graph.inbound(:x)`, `graph.both(:x)` are the same with the direction fixed.

What comes back:

| Method | Gives |
| --- | --- |
| relation methods (`where`, `order`, `pluck`, `count`, `each`, ...), `to_relation(Model)` | the reached nodes of one model as a relation (`Model.where(id: <the walk>)`) |
| `with_depth` | that relation with `graph_depth`, the fewest hops in the last step |
| `pairs`, `records` | `[[type, id], ...]` / loaded records, for walks that reach several models |
| `polymorphic(EntityLink.all, :target)` | rows whose polymorphic association points at any reached node: roll-ups |
| `by_origin` | `{start id => [reached nodes]}`, for a GraphQL dataloader batching many starts |
| `paths` | every simple path, `[[type, id], ...]` from start to end |
| `to_sql` | the statement, for EXPLAIN or a hand-written join |

`GraphQuery.from(relation)`, `GraphQuery.from_pairs([[Venue, id], ['Person', id]])` and
`GraphQuery.from_query(query)` start walks from anything.

## Cypher-style patterns

`GraphQuery.match(pattern, **bindings)` or `Model.where(...).graph_match(pattern)` (the scope binds the first node).
Linear patterns only: `(var:Label)`, `()`, `-[var:name|other*min..max]->`, `<-[...]-`, `-[...]-`, `-->`, `<--`,
`--`. Lengths: `*` (1 or more), `*2`, `*1..3`, `*..3`, `*0..`. Names may be written `CONTAINS` or `hasVenue`
(matched as `:contains`, `:has_venue`). Bind node variables to relations (conditions on those nodes) and relationship
variables to Hashes (edge conditions). `nodes(:v)` returns any node variable's matches; one in the middle of the
pattern only counts when it lies on a full match (the match walks back from the end to check). No branches, no
WHERE/RETURN text: bindings and relation methods do that job.

## How it runs

One `WITH RECURSIVE` statement per walk. Each step is a CTE over `(node_type, node_id)` rows; edges join through
`CROSS JOIN LATERAL`, so each hop reads the edge table through its index on the column that points back. Unbounded
steps keep a set and stop when nothing new turns up (cycles end them). Bounded steps keep a hop count. Unbounded steps
that also need a count (`depth: 2..`, `with_depth`, `paths`) stop at `GraphQuery.max_depth` (32). Node ids in one
walk must share a type (uuid everywhere, say). `paths` keeps every route, so use it to show a route, not on big graphs.

## Apache AGE

`GraphQuery::Age.available?` and `GraphQuery::Age.cypher(graph, query, columns:)` pass Cypher through to AGE where a
database has it. Heroku Postgres doesn't, so the CTE walker is the default and the only one AudienceKit uses.

## Tests

The examples live in `spec/support/graph_query_examples.rb` over a small graph in `gq_` tables. The host app runs
them (`spec/graph_query`); on their own: `GRAPH_QUERY_DATABASE_URL=postgres:///graph_query_test bundle exec rspec
-O /dev/null engines/graph_query/spec` from the app's root.
