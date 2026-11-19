# Results

A walk doesn't run until you ask for something. What you can ask for:

| Method | Gives |
| --- | --- |
| relation methods (`where`, `order`, `pluck`, `count`, `each`, `find_each`, `exists?`, ...) | the reached nodes, as a relation (the walk must reach one model) |
| `to_relation(Model)` / `nodes(Model)` | the reached nodes of one model, as a relation |
| `with_depth(Model)` | that relation plus `graph_depth`, the fewest hops in the last step |
| `pairs` | `[[type, id], ...]` for every node reached, whatever its model |
| `records` | every node reached, loaded, whatever its model |
| `polymorphic(scope, :name)` | rows of `scope` whose polymorphic association points at a reached node |
| `by_origin(Model)` | `{start id => [reached records]}` |
| `origin_pairs(Model)` | `[[start id, reached id], ...]`, unloaded |
| `paths` | every simple path, `[[type, id], ...]` from start to end |
| `to_sql(origin:, depth:, path:)` | the statement |
| `types` | the model names the walk can end on |

## Relations

When the last step reaches one model, a Query acts as a relation of it:

```ruby
venues = washington.traverse(:contains, depth: 0..).traverse(:has_venue)
venues.where(kind: 'bar').order(:name).limit(10).to_a
venues.count
venues.pluck(:id)
venues.includes(:locale).find_each { ... }
```

Under the hood that's `Venue.where(id: <the walk>)`, so it composes with scopes, joins, `merge` and pagination. If the
walk can reach several models, pick one: `query.to_relation(Event)`.

## Depth

`with_depth` joins the walk and selects each node's hop count in the last step as `graph_depth`:

```ruby
seattle.traverse(:within, depth: 1..).with_depth
       .reorder(Arel.sql('graph_query_nodes.depth DESC'))    # outermost first
       .pluck(:id)
```

Order by `graph_query_nodes.depth` rather than `graph_depth`: the alias doesn't survive `pluck`.

## Several models

```ruby
walk = venue.traverse(:rolls_up, depth: 1..)   # events and event series
walk.types     # => ["Event", "EventSeries"]
walk.pairs     # => [["Event", "4c1..."], ["EventSeries", "9ae..."], ...]
walk.records   # => [#<Event ...>, #<EventSeries ...>, ...] (one query per model)
```

## Roll-ups: `polymorphic`

Given a scope of rows with a polymorphic association, keep those pointing at any node the walk reaches. This is how
"everything linked to anything under this venue" works:

```ruby
venue.traverse(:rolls_up, depth: 0..)
     .polymorphic(EntityLink.where(audience_id:), :target)   # target_type / target_id
     .order(created_at: :desc)
```

The association's `foreign_type` / `foreign_key` are used if it's declared; otherwise `name_type` / `name_id`.

## Batching many starts: `by_origin`

Walk from many nodes in one statement and group what each reached, for a GraphQL dataloader:

```ruby
class LocalPeopleSource < GraphQL::Dataloader::Source
  def fetch(locale_ids)
    found = Locale.where(id: locale_ids).traverse(:contains, depth: 0..).traverse(:features).by_origin(Person)
    locale_ids.map { found.fetch(it, []) }
  end
end
```

`origin_pairs` gives the same as `[[locale_id, person_id], ...]` without loading anything.

## Paths

```ruby
GraphQuery.from(person).traverse(:knows, depth: 1..3).paths
# => [[["Person", "a"], ["Person", "b"]], [["Person", "a"], ["Person", "b"], ["Person", "c"]], ...]
```

Paths never revisit a node. Rows are routes, not nodes, so their number can grow fast: use `paths` to show a route,
not on big graphs.

## SQL

```ruby
query.to_sql                 # node_type, node_id
query.to_sql(origin: true)   # + origin_type, origin_id (the start node each row came from)
query.to_sql(depth: true)    # + depth (fewest hops in the last step)
query.to_sql(path: true)     # + path ('Type:id' text[])
```

Use it for `EXPLAIN ANALYZE`, or to join a walk by hand:

```ruby
Event.joins("JOIN (#{walk.to_sql}) g ON g.node_type = 'Event' AND g.node_id = events.id")
```
