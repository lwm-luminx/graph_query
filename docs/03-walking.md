# Walking

Start a walk from a scope, a record, or a whole model, and add steps with `traverse`:

```ruby
Locale.where(name: 'Washington').traverse(:contains, depth: 0..)   # from a scope
locale.traverse(:within, depth: 1..)                               # from one record
Venue.traverse(:hosts)                                             # from every row of a model
```

Each `traverse` returns a new `GraphQuery::Query` (queries are immutable), so steps chain:

```ruby
Locale.where(name: 'Washington')
      .traverse(:contains, depth: 0..)    # step 1: the state and everything in it
      .traverse(:has_venue)               # step 2: their venues
      .traverse(:hosts, to: Event)        # step 3: the events those venues host
```

## `traverse(names = nil, **options)`

`names` is a Symbol, an Array of Symbols (follow any of them), or `nil` / `:*` for every edge leaving the current
nodes.

| Option | Default | Meaning |
| --- | --- | --- |
| `depth:` | `1` | Hops, as an Integer or a Range. See below. |
| `direction:` | `:out` | `:out` (source to target), `:in` (target to source: ancestors, "who points at this"), or `:both`. |
| `to:` | any | Only arrive at these models: a model, a name, or an Array. |
| `where:` | none | Only arrive at nodes in this relation. An Array gives one relation per model (any may match). A Hash filters the one model the step reaches. |
| `through:` | none | Every node the step passes through, the last included, must be in this relation (or Array, one per model). Nodes of other models pass freely. |
| `edge_where:` | none | A Hash (or scope Proc) each edge's row must match. |

### depth

| Value | Reaches |
| --- | --- |
| `1` | nodes one hop away (the default) |
| `3` | nodes exactly three hops away |
| `1..3` | one to three hops away |
| `0..` | the start nodes and everything reachable |
| `1..` | everything reachable, not the start nodes |
| `2..` | everything at least two hops away |
| `0..1` | the start nodes and their neighbours |

A node counts if **some** route reaches it within the range. Walks that can go on forever (`1..`, `0..`) stop when no
new node turns up, so cycles end them. Unbounded walks that have to count hops (`2..`, `with_depth`, `paths`) stop at
`GraphQuery.max_depth`, 32 by default:

```ruby
GraphQuery.max_depth = 64
```

### direction

`:in` walks an edge backwards. With only `:contains` declared, you still get ancestors:

```ruby
seattle.traverse(:contains, direction: :in, depth: 1..)   # everything that contains Seattle
```

`out`, `inbound` and `both` are shorthands:

```ruby
query.out(:contains)       # traverse(:contains, direction: :out)
query.inbound(:contains)   # traverse(:contains, direction: :in)
query.both(:knows, depth: 1..2)
```

### to:, where:, through:

`to:` and `where:` filter where the step **arrives**; the walk still passes through other nodes on the way:

```ruby
# Every bar anywhere under Washington, but walk through every locale to find them.
washington.traverse(:contains, depth: 0..).traverse(:has_venue, where: Venue.where(kind: 'bar'))

# The same with a Hash, because the step reaches one model.
washington.traverse(:contains, depth: 0..).traverse(:has_venue, where: { kind: 'bar' })

# A step whose edges reach several models: arrive only at events.
venue.traverse(:rolls_up, depth: 1.., to: Event)
```

`through:` filters every node **on the way** (Cypher's `all(n IN nodes(p) WHERE ...)`). A node outside the relation
stops the walk there:

```ruby
# Only descend through active locales; a retired county hides everything under it.
washington.traverse(:contains, depth: 1.., through: Locale.where(retired_at: nil))
```

### edge_where:

Filters the edge rows themselves:

```ruby
event.traverse(:billed, edge_where: { role: 'headliner' })
person.traverse(:member_of, edge_where: -> { where(ended_at: nil) })
```

Like a missing property in Cypher, an edge kept in a table without the filter's columns doesn't match it, so a union
edge is narrowed to the parts that have the column. SQL edges match no filter.

## Starting elsewhere

```ruby
GraphQuery.from(Venue.where(kind: 'bar'))                 # any relation, record or model
GraphQuery.from_pairs([[Venue, venue_id], ['Person', person_id]])   # nodes of several models at once
GraphQuery.from_query(other_query)                        # the nodes another walk reached
Locale.where(...).graph                                   # a Query that hasn't moved yet; chain .out/.inbound
```

## Errors

- `GraphQuery::NoEdges`: the step names edges that don't leave the nodes it starts on (`no has_venue (out) from
  Person`), or its `to:` can't be reached. A step with `depth: 0..` from nodes with no such edges isn't an error: it
  keeps the nodes it started on.
- `GraphQuery::AmbiguousResult`: you asked for a relation, but the walk reaches several models. Name one, add `to:`,
  or use `pairs` / `records` / `polymorphic`.
- `ArgumentError`: a bad `depth:` or `direction:`.
