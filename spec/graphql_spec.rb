# frozen_string_literal: true

require_relative 'spec_helper'
require 'graph_query/graphql'

GraphQuery::GraphQL.type_for = ->(name) { "GqTypes::#{name.delete_prefix('Gq')}" }
GraphQuery::GraphQL.record_for = ->(model, id, _context) { model.find(id) }

module GqTypes
  class Venue < GraphQL::Schema::Object
    extend GraphQuery::GraphQL::Fields

    field :name, String, null: false
    graph_field :same_place, [Venue], edge: :same_place
  end

  class Event < GraphQL::Schema::Object
    field :name, String, null: false
  end

  class Place < GraphQL::Schema::Object
    extend GraphQuery::GraphQL::Fields

    field :id, ID, null: false
    field :name, String, null: false
    graph_field :children, [Place], edge: :contains, scope: ->(places, _) { places.order(:name) }
    graph_field :all_venues, [Venue], edge: %i[contains has_venue], depth: 0..,
                                      scope: ->(venues, _) { venues.order(:name) }
    graph_field :venue_page, Venue.connection_type, pattern: '()-[:contains*0..]->()-[:has_venue]->(v:GqVenue)',
                                                    scope: ->(venues, _) { venues.order(:name) }
    graph_field(:events, [Event], scope: ->(events, _) { events.order(:name) }) do |start|
      start.traverse(:contains, depth: 0..).traverse(:has_venue).traverse(:hosts, edge_where: { cancelled: false })
    end
    graph_edges GqPlace, only: %i[within rolls_up]
  end

  class Mutation < GraphQL::Schema::Object
    extend GraphQuery::GraphQL::MutationFields

    graph_mutations GqPlace
    field :link_venue, mutation: GraphQuery::GraphQL.edge_mutation(GqPlace, :has_venue, GqVenue)
  end

  class Query < GraphQL::Schema::Object
    field :places, [Place], null: false do
      argument :names, [String]
    end

    def places(names:) = GqPlace.where(name: names).order(:name)
  end

  class Schema < GraphQL::Schema
    query Query
    mutation Mutation
    use GraphQL::Dataloader
  end
end

RSpec.describe GraphQuery::GraphQL do
  let!(:usa) { GqPlace.create!(name: 'USA') }
  let!(:washington) { GqPlace.create!(name: 'Washington', parent: usa) }
  let!(:oregon) { GqPlace.create!(name: 'Oregon', parent: usa) }
  let!(:seattle) { GqPlace.create!(name: 'Seattle', parent: washington) }
  let!(:portland) { GqPlace.create!(name: 'Portland', parent: oregon) }
  let!(:eagle) { GqVenue.create!(name: 'Eagle', gq_place: seattle) }
  let!(:wildrose) { GqVenue.create!(name: 'Wildrose', gq_place: seattle) }
  let!(:crush) { GqVenue.create!(name: 'Crush', gq_place: portland) }

  before do
    GqEvent.create!(name: 'Leather Night', gq_venue: eagle)
    GqEvent.create!(name: 'Gone', gq_venue: eagle, cancelled: true)
    GqEvent.create!(name: 'Drag Brunch', gq_venue: crush)
  end

  def run(query, **variables)
    result = GqTypes::Schema.execute(query, variables: variables.transform_keys { it.to_s.camelize(:lower) })
    raise result['errors'].inspect if result['errors']

    result['data']
  end

  def statements(&)
    count = 0
    counter = lambda { |*, payload|
      count += 1 unless payload[:name] == 'SCHEMA' || payload[:sql].start_with?('SAVEPOINT', 'RELEASE')
    }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  it 'resolves graph fields for every object on the page in one statement each' do
    data = nil
    count = statements do
      data = run(<<~GRAPHQL)
        { places(names: ["Washington", "Oregon"]) { name children { name } allVenues { name } events { name } } }
      GRAPHQL
    end
    oregon = { 'name' => 'Oregon', 'children' => [{ 'name' => 'Portland' }], 'allVenues' => [{ 'name' => 'Crush' }],
               'events' => [{ 'name' => 'Drag Brunch' }] }
    washington = { 'name' => 'Washington', 'children' => [{ 'name' => 'Seattle' }],
                   'allVenues' => [{ 'name' => 'Eagle' }, { 'name' => 'Wildrose' }],
                   'events' => [{ 'name' => 'Leather Night' }] }
    expect(data['places']).to eq([oregon, washington])
    expect(count).to eq(1 + (3 * 2)) # the places, then for each graph field one walk and one load
  end

  it 'paginates a connection field, follows computed edges, and adds fields for declared edges' do
    data = run(<<~GRAPHQL)
      { places(names: ["USA"]) { venuePage(first: 2) { nodes { name samePlace { name } } pageInfo { hasNextPage } } } }
    GRAPHQL
    page = data['places'].first['venuePage']
    expect(page['nodes']).to eq([{ 'name' => 'Crush', 'samePlace' => [] },
                                 { 'name' => 'Eagle', 'samePlace' => [{ 'name' => 'Wildrose' }] }])
    expect(page['pageInfo']['hasNextPage']).to be(true)
    fields = GqTypes::Place.fields.keys
    expect(fields).to include('within', 'rollsUp')
    expect(run('{ places(names: ["Seattle"]) { within { name } rollsUp { name } } }')['places'])
      .to eq([{ 'within' => [{ 'name' => 'Washington' }],
                'rollsUp' => [{ 'name' => 'Eagle' }, { 'name' => 'Wildrose' }] }])
  end

  it 'exposes decorated graph mutations, loading records by ID, in one transaction' do
    hill = GqPlace.create!(name: 'Capitol Hill')
    data = run(<<~GRAPHQL, id: seattle.id, child: hill.id)
      mutation($id: ID!, $child: ID!) { gqPlaceAdopt(input: { id: $id, childId: $child }) { result { name } errors } }
    GRAPHQL
    expect(data['gqPlaceAdopt']).to eq('result' => { 'name' => 'Seattle' }, 'errors' => [])
    expect(hill.reload.parent_id).to eq(seattle.id)

    data = run(<<~GRAPHQL, id: portland.id, venues: [eagle.id, wildrose.id])
      mutation($id: ID!, $venues: [ID!]!) {
        gqPlaceTakeVenues(input: { id: $id, venueIds: $venues, fail: true }) { result { name } errors }
      }
    GRAPHQL
    expect(data['gqPlaceTakeVenues']).to eq('result' => nil, 'errors' => ['asked to fail'])
    expect(eagle.reload.gq_place_id).to eq(seattle.id)
  end

  it 'builds link mutations for an edge' do
    data = run(<<~GRAPHQL, from: portland.id, to: eagle.id)
      mutation($from: ID!, $to: ID!) { linkVenue(input: { fromId: $from, toId: $to }) { changed to { name } errors } }
    GRAPHQL
    expect(data['linkVenue']).to eq('changed' => true, 'to' => { 'name' => 'Eagle' }, 'errors' => [])
    expect(eagle.reload.gq_place_id).to eq(portland.id)
  end
end
