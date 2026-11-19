# Getting started

graph_query lets Active Record models on PostgreSQL be walked like a graph. You declare **edges** on your models from
the associations they already have, then **traverse** them in a Ruby chain or match them with a **Cypher-style
pattern**. Every walk compiles to one `WITH RECURSIVE` statement, and what comes back is an ordinary Active Record
relation you can keep chaining.

It needs nothing installed in the database: no Apache AGE, no extension. That is why it runs on Heroku Postgres.

## Install

In AudienceKit the engine lives at `engines/graph_query` and is loaded from the Gemfile by path, like `graphql_kit`:

```ruby
# Gemfile
gem 'graph_query', path: 'engines/graph_query'
```

It needs Ruby 4.0+, Active Record 7.1+ and the `pg` adapter. Once loaded, every Active Record model gets
`graph_edge`, `traverse`, `graph` and `graph_match`. There is no generator, migration or initializer.

## A first walk

The examples in this guide use a small, simplified schema (venues with a `kind`, events, people). The edges
AudienceKit really declares are listed under [In AudienceKit](#audiencekit).

Say locales nest (a state contains cities, a city contains neighborhoods) and venues belong to a locale:

```ruby
class Locale < ApplicationRecord
  belongs_to :parent, class_name: 'Locale', optional: true
  has_many :children, class_name: 'Locale', foreign_key: :parent_id
  has_many :venues

  graph_edge :contains, association: :children
  graph_edge :within, association: :parent
  graph_edge :has_venue, association: :venues
end
```

Now walk them:

```ruby
washington = Locale.where(name: 'Washington')

washington.traverse(:contains, depth: 0..)                       # the state and every locale inside it
washington.traverse(:contains, depth: 0..).traverse(:has_venue)  # every venue in the state
          .where(kind: 'bar').order(:name).limit(20)             # ... still a relation

seattle = Locale.find_by(name: 'Seattle')
seattle.traverse(:within, depth: 1..)                            # every locale Seattle lies within
```

The same walk as a pattern:

```ruby
GraphQuery.match('(s:Locale)-[:contains*0..]->()-[:has_venue]->(v:Venue)', s: washington)
          .where(kind: 'bar')
```

## The model in one paragraph

A **node** is a row of a model, named by `(node_type, node_id)`, where the type is the model's `polymorphic_name`.
An **edge** is a named kind of link from nodes of one model to nodes of another, read from a table: each row whose
source and target columns are both set is one edge. A **walk** starts from a set of nodes (a relation, a record, or
pairs) and takes **steps**; each step follows some edges one or more hops. The nodes the last step reaches are the
result.

## Where to go next

- [Declaring edges](#declaring-edges): every way to turn a table into edges.
- [Walking](#walking): the options a step takes.
- [Results](#results): relations, depths, pairs, paths, roll-ups and dataloaders.
- [Cypher-style patterns](#patterns): the same walks as text.
- [In AudienceKit](#audiencekit): the edges the API declares and the walks it runs.
- [How it runs](#internals): the SQL, performance and limits.
