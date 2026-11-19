# Writing edges

The edges you declare to read the graph can also write it. `GraphQuery.transaction` opens one database transaction
and gives you a `GraphQuery::Transaction` that links and unlinks by edge name:

```ruby
GraphQuery.transaction do |graph|
  hill = graph.create(Locale, name: 'Capitol Hill')
  graph.link(seattle, :contains, hill)                                   # sets locales.parent_id
  graph.link(northwest, :contains, hill, via: LocaleGrouping,            # creates a join row
                                         attributes: { role: 'core' })
  graph.relink(hill, :has_venue, eagle, from: downtown)                  # moves the venue
  graph.unlink(seattle, :has_venue, closed_bar)
end
```

## Where a write lands

An edge is written where it's kept:

| The edge is kept | `link` | `unlink` |
| --- | --- | --- |
| on the target's row (`has_many`, `has_one`) | sets the target's foreign key | clears it |
| on the source's row (`belongs_to`) | sets the source's foreign key | clears it |
| in a join model (`has_many :through`, `through:`) | creates a join row with the edge's Hash `where:` conditions and `attributes:` | destroys the matching rows |

Linking an edge that's already there, or unlinking one that isn't, changes nothing. SQL and computed edges can't be
written.

When several edges share a name between the same two models (a `has_many` and a join model, say), pass `via:` with
the model that holds the one you mean. Without it the transaction raises `GraphQuery::AmbiguousResult`.

## Methods

| Method | |
| --- | --- |
| `link(from, name, to, via: nil, attributes: {})` | add the edge |
| `unlink(from, name, to, via: nil)` | remove it |
| `relink(new_from, name, to, from:, via: nil, attributes: {})` | unlink from `from:`, link from `new_from` |
| `linked?(from, name, to, via: nil)` | whether the edge is there |
| `create(model, **attributes)`, `update(record, **attributes)`, `destroy(record)` | write nodes in the same transaction |
| `changes` | what was written, in order: `Change(action, edge, from, to, record)` |

Rows are saved with `save!` and `destroy!`, so validations and callbacks run. Any exception rolls every write back.
`GraphQuery.transaction` nests inside an outer transaction as a savepoint.

## Graph mutations

A graph mutation is a model method that writes the graph, marked so that it runs in a transaction and can be
exposed to GraphQL. Put `graph_mutation` on the line before the `def`:

```ruby
class Locale < ApplicationRecord
  graph_mutation arguments: { child: Locale, role: String }, description: 'Make child a member of this locale.'
  def adopt(child:, role: nil, graph:)
    graph.link(self, :contains, child, via: LocaleGrouping, attributes: { role: })
    self
  end

  graph_mutation def close = update!(closed_at: Time.current) && self   # or in front of it, with no options

  graph_mutation arguments: { venues: [Venue] }, returns: Venue
  def take_venues(venues:, graph:)
    venues.each { graph.relink(self, :has_venue, it, from: it.locale) }
    venues.first
  end
end

northwest.adopt(child: seattle)       # runs in GraphQuery.transaction; graph: is filled in
Locale.graph_mutations                # => { adopt: #<GraphQuery::Mutation Locale#adopt>, take_venues: ... }
```

- The method runs inside `GraphQuery.transaction`. If it takes a `graph:` keyword, it's given the transaction.
- `arguments:` types each keyword for GraphQL. A model takes an ID, `[Model]` takes a list of IDs,
  and `String`, `Integer`, `Float`, `:boolean`, `:id`, `:json`, `Date`, `Time` or a GraphQL type pass straight
  through. Required keywords become required arguments.
- `returns:` types the result. The default is the model.
- Models may be given as classes or as names (`'Venue'`); a name avoids loading a model the class body can't see yet.
- Calling the method from Ruby works the same way, so the same write path backs a console, a job and the API.

See [GraphQL](#graphql) for turning these into mutation fields.
