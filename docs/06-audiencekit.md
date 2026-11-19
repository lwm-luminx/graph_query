# In AudienceKit

The API declares its edges on the models and keeps its named walks in `app/queries/graph.rb`. No recursive SQL is
written anywhere else in `app/` (`spec/queries/graph_isolation_spec.rb` checks), so if PostgreSQL ships SQL/PGQ
(`GRAPH_TABLE`), only the engine's compiler has to change, behind the same specs.

## The edges

| Model | Edge | To | From |
| --- | --- | --- | --- |
| Locale | `:contains` | Locale | `children` (parent_id), and `LocaleGrouping` super_locale_id → member_locale_id |
| Locale | `:within` | Locale | `parent` |
| Locale | `:features` | Person | `people` (through person_locales) |
| Locale | `:rolls_up` | Venue, Event, EventSeries | `venues`, `events`, and `event_series.locale_id` |
| Venue | `:rolls_up` | Event, EventSeries | `all_events`, `hosted_event_series` |
| EventSeries | `:rolls_up` | Event | `events` |
| Person | `:rolls_up` | Event, EventSeries | `EventPerson` (billed), `EventSeriesHost` (hosted) |
| Credit | `:derived_from` | Credit | `derived_from` |

`:contains` follows both the jurisdiction tree and super locales; `:within` follows only the parent chain, because
liquor rules and time zones come down the jurisdiction chain only.

## The walks (`Graph`)

```ruby
Graph.locale_subtree_ids(ids)      # these locales and every locale within them
  # Locale.where(id: ids).traverse(:contains, depth: 0..).pluck(:id)

Graph.locale_people_pairs(ids)     # [[locale_id, person_id], ...] for people featured in each subtree
  # Locale.where(id: ids).traverse(:contains, depth: 0..).traverse(:features).origin_pairs

Graph.locale_ancestor_ids(id)      # parent chain, outermost first
  # Locale.where(id:).traverse(:within, depth: 1..Locale::MAX_DEPTH).with_depth
  #       .reorder(Arel.sql('graph_query_nodes.depth DESC')).pluck(:id)

Graph.credit_chain_ids(id)         # the credits a credit was republished from, original first
  # Credit.where(id:).traverse(:derived_from, depth: 0..16).with_depth
  #       .reorder(Arel.sql('graph_query_nodes.depth DESC')).pluck(:id)

Graph.roll_up_scope(record)        # everything a record's roll-ups come from, itself included
  # record.traverse(:rolls_up, depth: 0..)
```

## Roll-ups

`RollUp#links` shows the entity links on a record and on everything under it:

```ruby
Graph.roll_up_scope(subject)
     .polymorphic(EntityLink.where(audience_id:), :target)
     .order(created_at: :desc, id: :asc)
```

Roll-ups are transitive: a person's page takes in the series they host **and those series' events**; a locale takes in
its venues, their events and series, and their events. A locale does not take in its sub-locales' items (`:rolls_up`
doesn't follow `:contains`). To add a new kind of roll-up, declare another `graph_edge :rolls_up` on the model; nothing
in `RollUp` changes. See `doc/ROLL_UP.md`.

## Adding a walk

1. Declare the edge on the model it leaves (`graph_edge`), from an association where one exists.
2. Put the walk in `Graph` (or call `traverse` where it's used, if it's a one-off).
3. Test it against real rows; the engine's own behaviour is covered by `spec/graph_query`.
