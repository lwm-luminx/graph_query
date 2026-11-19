# graph_query

[![CI](https://github.com/lwm-luminx/graph_query/actions/workflows/ci.yml/badge.svg)](https://github.com/lwm-luminx/graph_query/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/graph_query.svg)](https://rubygems.org/gems/graph_query)

Graph traversals and Cypher queries for Active Record on PostgreSQL. Declare edges on your models from the
associations they already have; walk them in a Ruby chain, a Cypher-style pattern or a Cypher query; get Active Record
relations back. Every walk is one recursive CTE, so it needs nothing installed in the database: no Apache AGE, no
extension. It runs on Heroku Postgres, RDS, Supabase or your laptop.

**Docs: https://lwm-luminx.github.io/graph_query/**

```ruby
gem 'graph_query'
```

```ruby
class Locale < ApplicationRecord
  has_many :children, class_name: 'Locale', foreign_key: :parent_id
  has_many :venues

  graph_edge :contains, association: :children
  graph_edge :contains, to: 'Locale', through: 'LocaleGrouping', source: :super_locale_id, target: :member_locale_id
  graph_edge :has_venue, association: :venues
end

class Venue < ApplicationRecord
  graph_edge :hosts, association: :events
end

washington = Locale.where(name: 'Washington')
washington.traverse(:contains, depth: 0..)                              # the state and everything in it
washington.traverse(:contains, depth: 0..).traverse(:has_venue)         # every venue in the state
  .where(kind: 'bar').order(:name)                                      # ... still a relation
seattle.traverse(:contains, direction: :in, depth: 1..)                 # everything Seattle lies within

GraphQuery.match('(s:Locale)-[:contains*0..]->()-[:has_venue]->(v:Venue)-[:hosts]->(e:Event)',
                 s: washington, e: Event.upcoming).nodes(:v)            # venues with upcoming events

GraphQuery.cypher(<<~CYPHER, state: 'Washington')                       # the same, as Cypher
  MATCH (s:Locale {name: $state})-[:contains*0..]->()-[:has_venue]->(v:Venue)-[:hosts]->(e:Event)
  WHERE e.starts_at > '2026-12-01' AND v.kind = 'bar'
  RETURN v ORDER BY v.name LIMIT 20
CYPHER
```

## What's in it

- **Edges** from `belongs_to`, `has_many`/`has_one` and `has_many :through` associations, from a join model named
  outright, or from SQL. Several declarations with one name union into one kind of edge.
- **Walks** with any depth (`1`, `2..4`, `0..`, `1..`), in any direction, filtered on where they arrive (`to:`,
  `where:`), on every node they pass (`through:`), and on the edges' own rows (`edge_where:`). Cycles end unbounded
  walks.
- **Results** as relations, plus hop counts (`with_depth`), mixed-model `pairs`/`records`, polymorphic roll-ups
  (`polymorphic(Comment.all, :commentable)`), per-start grouping for GraphQL dataloaders (`by_origin`), and `paths`.
- **Patterns** (`GraphQuery.match`) and **Cypher** (`GraphQuery.cypher`): `MATCH` with property maps and several
  paths, `WHERE`, `RETURN`, `ORDER BY`, `SKIP`, `LIMIT`, `$params`.
- **Types**: RBS signatures in `sig/` and a Sorbet RBI in `rbi/`.
- **Speed**: edges join through `CROSS JOIN LATERAL`, so each hop reads the edge table through its index.

Requires Ruby 4.0+, Active Record 7.1+ and PostgreSQL.

## Docs

The guide is in [docs/](docs/) and published at https://lwm-luminx.github.io/graph_query/:
[getting started](docs/01-getting-started.md), [declaring edges](docs/02-declaring-edges.md),
[walking](docs/03-walking.md), [results](docs/04-results.md), [patterns](docs/05-patterns.md),
[Cypher queries](docs/06-cypher.md), [how it runs](docs/07-internals.md) and the [reference](docs/08-reference.md).

## Development

```sh
bundle install
createdb graph_query_test
GRAPH_QUERY_DATABASE_URL=postgres:///graph_query_test bundle exec rake   # specs, RuboCop, rbs validate
bundle exec rake docs                                                     # builds the docs site into site/ (needs pandoc)
```

The specs are shared examples (`spec/support/graph_query_examples.rb`) over a small graph in `gq_` tables, so an app
can run the same examples against its own database.

## Releasing

Bump `GraphQuery::VERSION` and `CHANGELOG.md`, merge to main, then push a tag `vX.Y.Z`. The Release workflow runs the
specs, checks the tag matches the version, publishes the gem to RubyGems with trusted publishing (no API key is
stored), and creates a GitHub release.

## License

MIT, copyright Love Wins Media, Inc. See [LICENSE.txt](LICENSE.txt). graph_query was built for
[AudienceKit](https://audiencekit.com).
