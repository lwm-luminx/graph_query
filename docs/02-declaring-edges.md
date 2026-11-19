# Declaring edges

Call `graph_edge name, ...` on the model the edge **leaves**. The name is a Symbol you pick (`:contains`,
`:has_venue`, `:rolls_up`). Several declarations with one name make one kind of edge that unions them, even across
models and target types.

## From an association

The usual way. Name an association the model already has, and graph_query reads the edge from the table that holds
the foreign key.

| Association | Rows that are edges | Example |
| --- | --- | --- |
| `has_many` / `has_one` | the target's rows, pointing back with the foreign key | `graph_edge :contains, association: :children` |
| `belongs_to` | the owner's rows with the foreign key set | `graph_edge :within, association: :parent` |
| `has_many :through` a join model that `belongs_to` the target | the join model's rows | `graph_edge :billed_on, association: :events` |

What carries over from the association:

- **Its scope.** `has_many :published_posts, -> { where(published: true) }` makes edges only to published posts. The
  scope must not take the owner record (a scope with an argument can't be walked, since there is no one owner).
- **`as:`** on a polymorphic `has_many` adds a condition on the type column, so only rows pointing at this model count.
- **The join model's scope** on a `:through` association.

What can't be an edge (each raises `ArgumentError` when the edge is first built):

- A polymorphic `belongs_to`: it has no one target model. Declare one edge per target with `through:` or `sql:`.
- A `:through` association with its own scope: that scope filters the target, not the join rows. Use `through:`
  with `where:` instead.
- A `:through` chain through another `:through`, or one whose source isn't a `belongs_to`.

## From a join model, named outright

When there's no association, or you need a different shape, name the table's model and its two columns:

```ruby
class Locale < ApplicationRecord
  graph_edge :contains, to: 'Locale', through: 'LocaleGrouping',
                        source: :super_locale_id, target: :member_locale_id
end
```

- `to:` the model the edge arrives at (a name; the model needn't be loaded yet).
- `through:` the model whose table holds the rows. It can be the target itself:
  `graph_edge :rolls_up, to: 'EventSeries', through: 'EventSeries', source: :locale_id, target: :id`.
- `source:` the column holding the id of the node the edge leaves (defaults to the model's `foreign_key`).
- `target:` the column holding the id of the node it arrives at.

## From SQL

For anything else, give SQL selecting `source_id` and `target_id`:

```ruby
class Venue < ApplicationRecord
  graph_edge :near, to: 'Venue', sql: <<~SQL
    SELECT a.id AS source_id, b.id AS target_id
    FROM venues a JOIN venues b ON a.id <> b.id AND ST_DWithin(a.location, b.location, 500)
  SQL
end
```

SQL edges can't take `edge_where:` filters (there's no model to check columns against), and the planner can only use
indexes if it can push the `source_id = ...` condition into your SQL.

## Filtering an edge's rows: `where:`

Every form takes `where:`, a Hash or a scope Proc run on the edge's table:

```ruby
graph_edge :headlines, association: :event_people, where: { role: 'headliner' }
graph_edge :current_members, to: 'Person', through: 'Membership', source: :group_id, target: :person_id,
                             where: -> { where(ended_at: nil) }
```

## Unions

Declarations with the same name are one edge kind. A walk over `:contains` follows both of these:

```ruby
graph_edge :contains, association: :children                       # a locale's sub-locales
graph_edge :contains, to: 'Locale', through: 'LocaleGrouping',      # and, for a super locale, its members
                      source: :super_locale_id, target: :member_locale_id
```

Edges with one name can also arrive at different models: AudienceKit's `:rolls_up` goes from a venue to its events
**and** its hosted series.

## When edges are built

Declarations are lazy. They're stored as builders and turned into edges the first time a query needs them, so a
declaration may name a model that isn't loaded yet, and model classes can be declared in any order. When Rails reloads
a model, its declarations replace the old ones instead of adding to them.

To see what's declared:

```ruby
GraphQuery.registry.all
# => [#<GraphQuery::Edge Locale -[:contains]-> Locale>, #<GraphQuery::Edge Locale -[:within]-> Locale>, ...]
```

## Ids

Node ids in one walk must share a SQL type, because each step's rows are unioned into one `node_id` column. Use uuid
everywhere, or bigint everywhere.
