# Cypher-style patterns

`GraphQuery.match(pattern, **bindings)` runs a linear Cypher-style pattern. It builds the same steps as `traverse`, so
everything about walks applies.

```ruby
GraphQuery.match(
  '(s:Locale)-[:contains*0..]->()-[:has_venue]->(v:Venue)-[:hosts]->(e:Event)<-[:billed_on]-(p:Person)',
  s: Locale.where(name: 'Washington'),
  e: Event.upcoming
).nodes(:v)   # venues in Washington where someone is billed on an upcoming event
```

From a scope, the scope binds the first node:

```ruby
Locale.where(name: 'Seattle').graph_match('(l)-[:contains*0..]->()-[:has_venue]->(v:Venue)')
```

## Syntax

| Part | Means |
| --- | --- |
| `(v)`, `(v:Venue)`, `(:Venue|Event)`, `()` | a node, with an optional variable and labels (models) |
| `-[:has_venue]->` | one hop out along `has_venue` |
| `<-[:hosts]-` | one hop in (walk `hosts` backwards) |
| `-[:knows]-` | one hop either way |
| `-[r:billed_on|hosts]->` | either edge, with a variable to bind conditions to |
| `-->`, `<--`, `--` | any edge, one hop |
| `*` | one or more hops |
| `*2` | exactly two |
| `*1..3`, `*..3` | one to three |
| `*0..` | zero or more (the node itself too) |

Names may be written as in Cypher: `CONTAINS` and `hasVenue` match `:contains` and `:has_venue`. Labels are model
names (`event_series` and `EventSeries` both work).

## Bindings

There's no `WHERE` or `RETURN` text. Bind variables instead:

- **A node variable** to a relation (or record, or model): the node must be in it. `v: Venue.where(kind: 'bar')`.
- **A relationship variable** to a Hash or scope Proc: an `edge_where:` on that step.
  `GraphQuery.match('(e:Event)<-[b:billed_on]-(p:Person)', e: event, b: { role: 'headliner' })`.

The first node must be bound or have exactly one label (`(s:Locale)` alone starts from every locale).

## Results

A Match acts as a relation of the **last** node's matches, like a Query. For another node, use `nodes(:var)`:

```ruby
match = GraphQuery.match('(s:Locale)-[:contains*0..]->(l)-[:has_venue]->(v:Venue)', s: washington,
                         v: Venue.where(kind: 'bar'))
match.count          # bars
match.nodes(:l)      # only the locales that have a bar under them
match.paths          # each full route
match.query          # the underlying GraphQuery::Query
```

A variable in the middle counts only nodes that lie on a full match: graph_query walks forward to that node, walks
back from the end of every full match to it, and keeps the overlap.

## Not supported

Branching patterns (`(a)-->(b), (a)-->(c)`), properties in braces (`{name: 'x'}`), `WHERE`, `RETURN`, `OPTIONAL MATCH`
and aggregation. Bindings and relation methods do those jobs; for anything more, chain `traverse` steps or use
`from_query` to start a second walk from the first one's result.
