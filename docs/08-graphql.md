# GraphQL

`require 'graph_query/graphql'` adds [graphql-ruby](https://graphql-ruby.org) support (graphql 2.3 or later; the gem
doesn't depend on it otherwise). Declared edges back fields, and graph mutations back mutation fields.

## Fields backed by walks

Extend an object type with `GraphQuery::GraphQL::Fields`, then declare fields by edge, pattern or block:

```ruby
class Types::LocaleType < Types::BaseObject
  extend GraphQuery::GraphQL::Fields

  graph_field :children, [Types::LocaleType], edge: :contains                       # one hop
  graph_field :venues, [Types::VenueType], edge: %i[contains has_venue], depth: 0.. # contains*0.. then has_venue
  graph_field :bars, Types::VenueType.connection_type,                              # paginated
              pattern: '()-[:contains*0..]->()-[:has_venue]->(v:Venue)',
              scope: ->(venues, context) { venues.where(kind: 'bar').order(:name) }
  graph_field(:events, [Types::EventType]) do |start|                               # anything a Query can do
    start.traverse(:contains, depth: 0..).traverse(:has_venue).traverse(:hosts, edge_where: { cancelled: false })
  end
end
```

| Option | |
| --- | --- |
| `edge:` | an edge name, or several walked in turn (`depth:` and the other walk options apply to all but the last) |
| `pattern:` | a [pattern](#patterns) whose first node is the object; the field returns the last node |
| a block | given `GraphQuery.from(object)`, returns a Query |
| `depth:`, `direction:`, `to:`, `through:`, `edge_where:` | as in [walking](#walking) |
| `scope:` | `->(relation, context)` to filter, order or authorize the result |
| `model:` | the result's model, when the walk can reach several |

A list field is **batched**. graph_query loads it through `GraphQL::Dataloader`, so 50 locales asking for their
venues run one walk from all 50 (with `origin_pairs`) and one load, not 50 of each. Add `use GraphQL::Dataloader` to
the schema. A connection field returns a relation per object, so graphql-ruby paginates it in SQL.

## A field per declared edge

`graph_edges` adds a list field for every edge a model declares, one hop out:

```ruby
class Types::LocaleType < Types::BaseObject
  extend GraphQuery::GraphQL::Fields
  graph_edges Locale, only: %i[within rolls_up]   # within: [LocaleType], rolls_up_venues, rolls_up_events ...
end
```

A field is named after its edge, or `edge_targets` when one edge name reaches several models. `except:` leaves edges
out, and `scope:` applies to every field.

Types are found by model name through `GraphQuery::GraphQL.type_for`. The default returns `"Types::<Model>Type"`,
which graphql-ruby resolves lazily, so a type can list edges back to itself. Set your own when the types are named
differently:

```ruby
GraphQuery::GraphQL.type_for = ->(model_name) { "Types::#{model_name}Object" }
```

## Mutations from graph mutations

Extend the mutation type with `GraphQuery::GraphQL::MutationFields` and name the models:

```ruby
class Types::MutationType < Types::BaseObject
  extend GraphQuery::GraphQL::MutationFields
  graph_mutations Locale, Venue                  # localeAdopt, localeTakeVenues, ...
end
```

Each [graph mutation](#writes) becomes a Relay-style mutation named `<model>_<method>`:

```graphql
mutation {
  localeAdopt(input: { id: "...", childId: "...", role: "core" }) { result { name } errors }
}
```

- `id` finds the record to call the method on. Model arguments become `childId` / `venueIds` and are loaded through
  `GraphQuery::GraphQL.record_for`. By default that's the schema's `object_from_id`, falling back to `Model.find`.
- `result` is what the method returns, typed by `returns:`. `errors` lists messages.
- The whole mutation runs in one transaction. A validation failure, a `GraphQuery::Error` or a returned `errors`
  rolls it back and comes back in `errors`.
- `only:` and `except:` pick methods, and `base:` sets the mutation base class.

## Other mutations

For a mutation written by hand, include `GraphQuery::GraphQL::TransactionalMutation`. `resolve` then runs in one
transaction with `graph` open:

```ruby
class Mutations::MoveVenue < Types::BaseMutation
  include GraphQuery::GraphQL::TransactionalMutation
  argument :venue_id, ID
  argument :locale_id, ID
  field :venue, Types::VenueType
  field :errors, [String], null: false

  def resolve(venue_id:, locale_id:)
    venue = Venue.find(venue_id)
    graph.relink(Locale.find(locale_id), :has_venue, venue, from: venue.locale)
    { venue: venue.reload, errors: [] }
  end
end
```

Without an `errors` field, failures are raised as `GraphQL::ExecutionError`.

To link or unlink one edge by ID, `edge_mutation` builds the whole class:

```ruby
field :add_venue, mutation: GraphQuery::GraphQL.edge_mutation(Locale, :has_venue, Venue)
field :remove_venue, mutation: GraphQuery::GraphQL.edge_mutation(Locale, :has_venue, Venue, action: :unlink)
# addVenue(input: { fromId: "...", toId: "..." }) { changed from { name } to { name } errors }
```

Authorize these the way you authorize any graphql-ruby mutation (`ready?`, `authorized?`, or the base class you pass
as `base:`).
