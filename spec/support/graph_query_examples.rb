# frozen_string_literal: true

# Examples shared by the engine's own run (spec/graph_query_spec.rb) and the host app's.
RSpec.shared_examples 'graph_query' do
  let!(:usa) { GqPlace.create!(name: 'USA', kind: 'country') }
  let!(:washington) { GqPlace.create!(name: 'Washington', kind: 'state', parent: usa) }
  let!(:king) { GqPlace.create!(name: 'King County', kind: 'county', parent: washington) }
  let!(:seattle) { GqPlace.create!(name: 'Seattle', kind: 'city', parent: king) }
  let!(:spokane) { GqPlace.create!(name: 'Spokane', kind: 'city', parent: washington) }
  let!(:oregon) { GqPlace.create!(name: 'Oregon', kind: 'state', parent: usa) }
  let!(:portland) { GqPlace.create!(name: 'Portland', kind: 'city', parent: oregon) }
  let!(:northwest) { GqPlace.create!(name: 'Pacific Northwest', kind: 'metro') }
  let!(:eagle) { GqVenue.create!(name: 'Eagle', gq_place: seattle) }
  let!(:wildrose) { GqVenue.create!(name: 'Wildrose', gq_place: seattle) }
  let!(:globe) { GqVenue.create!(name: 'Globe', gq_place: spokane) }
  let!(:crush) { GqVenue.create!(name: 'Crush', gq_place: portland) }
  let!(:leather_night) { GqEvent.create!(name: 'Leather Night', gq_venue: eagle) }
  let!(:cancelled_night) { GqEvent.create!(name: 'Cancelled Night', gq_venue: eagle, cancelled: true) }
  let!(:karaoke) { GqEvent.create!(name: 'Karaoke', gq_venue: wildrose) }
  let!(:drag_brunch) { GqEvent.create!(name: 'Drag Brunch', gq_venue: crush) }
  let!(:drew) { GqPerson.create!(name: 'Drew', gq_events: [leather_night, drag_brunch]) }

  before do
    GqGrouping.create!(super_place_id: northwest.id, member_place_id: seattle.id, role: 'core')
    GqGrouping.create!(super_place_id: northwest.id, member_place_id: portland.id, role: 'nearby')
  end

  def names(relation) = relation.map(&:name).sort

  describe 'traverse' do
    it 'walks every depth from a scope, the scope included with depth 0..' do
      expect(names(GqPlace.where(id: washington).traverse(:contains, depth: 0..)))
        .to eq(['King County', 'Seattle', 'Spokane', 'Washington'])
    end

    it 'walks one hop by default' do
      expect(names(washington.traverse(:contains))).to eq(['King County', 'Spokane'])
    end

    it 'unions every declaration of an edge name (children and super locale members)' do
      expect(names(northwest.traverse(:contains, depth: 1..))).to eq(%w[Portland Seattle])
    end

    it 'walks edges backwards, and belongs_to edges forwards' do
      expect(names(seattle.traverse(:contains, direction: :in, depth: 1..)))
        .to eq(['King County', 'Pacific Northwest', 'USA', 'Washington'])
      expect(names(seattle.traverse(:within, depth: 1..))).to eq(['King County', 'USA', 'Washington'])
    end

    it 'keeps bounded depths' do
      expect(names(usa.traverse(:contains, depth: 2))).to eq(['King County', 'Portland', 'Spokane'])
      expect(names(usa.traverse(:contains, depth: 2..3))).to eq(['King County', 'Portland', 'Seattle', 'Spokane'])
    end

    it 'chains steps across models and stays a relation' do
      venues = GqPlace.where(name: 'Washington').traverse(:contains, depth: 0..).traverse(:has_venue)
      expect(names(venues)).to eq(%w[Eagle Globe Wildrose])
      expect(venues.where.not(name: 'Globe').order(:name).pluck(:name)).to eq(%w[Eagle Wildrose])
      expect(venues.to_relation).to be_a(ActiveRecord::Relation)
      expect(names(venues.where(name: 'Eagle').traverse(:hosts))).to eq(['Cancelled Night', 'Leather Night'])
    end

    it "applies a has_many association's own scope" do
      expect(names(eagle.traverse(:hosts_live))).to eq(['Leather Night'])
    end

    it 'walks has_many :through join rows both ways' do
      expect(names(drew.traverse(:billed_on))).to eq(['Drag Brunch', 'Leather Night'])
      expect(names(leather_night.graph.inbound(:billed_on))).to eq(['Drew'])
    end

    it 'filters edges, arrivals and the nodes passed through' do
      expect(names(northwest.traverse(:contains, edge_where: { role: 'core' }))).to eq(['Seattle'])
      expect(names(usa.traverse(:contains, depth: 1..,
                                           where: GqPlace.where(kind: 'city')))).to eq(%w[Portland Seattle Spokane])
      expect(names(usa.traverse(:contains, depth: 1.., through: GqPlace.where.not(kind: 'county'))))
        .to eq(%w[Oregon Portland Spokane Washington])
    end

    it 'ends on cycles' do
      GqGrouping.create!(super_place_id: seattle.id, member_place_id: usa.id)
      expect(seattle.traverse(:contains, depth: 1..).count).to eq(7)
      expect(seattle.traverse(:contains, depth: 2..).count).to eq(7)
      expect(seattle.traverse(:contains, depth: 1..).paths.map(&:size).max).to be <= 8
    end

    it 'reports hop counts, origins and paths' do
      depths = usa.traverse(:contains, depth: 1..).with_depth.to_h { [it.name, it.graph_depth] }
      expect(depths).to include('Washington' => 1, 'King County' => 2, 'Seattle' => 3)
      by_origin = GqPlace.where(id: [king, oregon]).traverse(:contains, depth: 0..).traverse(:has_venue).by_origin
      expect(by_origin.transform_values { names(it) }).to eq(king.id => %w[Eagle Wildrose], oregon.id => ['Crush'])
      expect(washington.traverse(:contains, depth: 1..).exists?(name: 'Seattle')).to be(true)
      expect(washington.traverse(:contains,
                                 depth: 2).paths).to eq([[['GqPlace', washington.id], ['GqPlace', king.id],
                                                          ['GqPlace', seattle.id]]])
    end
  end

  describe 'walks over several models' do
    let!(:on_event) { GqLink.create!(title: 'episode at Leather Night', target: leather_night) }
    let!(:on_venue) { GqLink.create!(title: 'feature on Eagle', target: eagle) }
    let(:under_seattle) { seattle.traverse(%i[contains rolls_up], depth: 0..) }

    before { GqLink.create!(title: 'episode at Drag Brunch', target: drag_brunch) }

    it 'rolls up polymorphic links from everything under a node' do
      under_eagle = eagle.traverse(:rolls_up, depth: 0..)
      expect(under_eagle.polymorphic(GqLink.all, :target)).to contain_exactly(on_event, on_venue)
      expect(under_seattle.types).to contain_exactly('GqPlace', 'GqVenue', 'GqEvent')
      expect(under_seattle.polymorphic(GqLink.all, :target)).to contain_exactly(on_event, on_venue)
    end

    it 'returns several models as pairs or records, and one model when named' do
      expect { under_seattle.to_relation }.to raise_error(GraphQuery::AmbiguousResult)
      expect(names(under_seattle.to_relation(GqEvent))).to eq(['Cancelled Night', 'Karaoke', 'Leather Night'])
      expect(under_seattle.pairs).to include(['GqVenue', eagle.id], ['GqEvent', karaoke.id])
      expect(under_seattle.records).to include(seattle, wildrose, karaoke)
    end

    it 'starts from nodes of several models' do
      query = GraphQuery.from_pairs([[GqVenue, crush.id], ['GqPerson', drew.id]]).traverse(%i[hosts billed_on])
      expect(names(query)).to eq(['Drag Brunch', 'Leather Night'])
    end

    it 'says which edges are missing, unless the step may stay put' do
      expect { GqEvent.all.traverse(:contains).to_a }.to raise_error(GraphQuery::NoEdges, /contains/)
      expect(names(leather_night.traverse(:rolls_up, depth: 0..))).to eq(['Leather Night'])
      expect(leather_night.traverse(:rolls_up, depth: 0..).with_depth.map(&:graph_depth)).to eq([0])
    end

    it 'pairs each start with what it reaches' do
      pairs = GqPlace.where(id: [king, oregon]).traverse(:contains, depth: 0..).traverse(:has_venue).origin_pairs
      expect(pairs).to contain_exactly([king.id, eagle.id], [king.id, wildrose.id], [oregon.id, crush.id])
    end
  end

  describe 'match' do
    let(:pattern) do
      '(s:GqPlace)-[:CONTAINS*0..]->()-[:hasVenue]->(v:GqVenue)-[:hosts]->(e:GqEvent)<-[:billed_on]-(p:GqPerson)'
    end

    it 'runs a Cypher-style pattern and returns its last node' do
      expect(names(GraphQuery.match(pattern, s: GqPlace.where(id: washington)))).to eq(['Drew'])
    end

    it 'returns nodes in the middle of the pattern that lie on a full match' do
      match = GraphQuery.match(pattern, s: GqPlace.where(id: usa))
      expect(names(match.nodes(:v))).to eq(%w[Crush Eagle])
      expect(names(match.nodes(:e))).to eq(['Drag Brunch', 'Leather Night'])
      expect(names(match.nodes(:s))).to eq(['USA'])
    end

    it 'binds nodes to relations and edges to conditions' do
      match = GraphQuery.match('(n)-[r:contains]->(c)-[:has_venue]->(v)', n: northwest, r: { role: 'nearby' })
      expect(names(match)).to eq(['Crush'])
      expect(names(GqVenue.where(name: 'Eagle').graph_match('()<--(l:GqPlace)'))).to eq(['Seattle'])
      expect(names(GraphQuery.match('(e:GqEvent)<-[:hosts]-(v)', e: GqEvent.where(cancelled: true)))).to eq(['Eagle'])
    end

    it 'parses lengths and directions' do
      rels = GraphQuery::Pattern.parse('(a)-[*]->(b)<-[x:one|two*2]-(c)-[*..3]-(d)--(e)').rels
      shapes = rels.map { [it.direction, it.min, it.max] }
      expect(shapes).to eq([[:out, 1, nil], [:in, 2, 2], [:both, 1, 3], [:both, 1, 1]])
      expect(rels[1].names).to eq(%i[one two])
      expect { GraphQuery::Pattern.parse('(a)<-[]->(b)') }.to raise_error(GraphQuery::PatternError)
      expect { GraphQuery::Pattern.parse('(a)-[:x') }.to raise_error(GraphQuery::PatternError)
    end

    it 'reads property maps, with params' do
      match = GraphQuery.match('(s:GqPlace {kind: $kind})-[:contains {role: "nearby"}]->(c)', params: { kind: 'metro' })
      expect(names(match)).to eq(['Portland'])
      node = GraphQuery::Pattern.parse("(v:GqVenue {name: 'Eagle', open: true, n: -1.5, tags: ['a'], m: {x: null}})")
                                .nodes.first
      expect(node.props).to eq(name: 'Eagle', open: true, n: -1.5, tags: ['a'], m: { x: nil })
    end
  end

  describe 'cypher' do
    def cypher(query, **params) = GraphQuery.cypher(query, **params)

    it 'runs MATCH ... RETURN with property maps and params' do
      result = cypher('MATCH (s:GqPlace {name: $state})-[:contains*0..]->()-[:has_venue]->(v:GqVenue) RETURN v',
                      state: 'Washington')
      expect(names(result)).to eq(%w[Eagle Globe Wildrose])
      expect(result).to be_a(ActiveRecord::Relation)
    end

    it 'filters with WHERE on any variable, the middle ones included' do
      query = <<~CYPHER
        MATCH (s:GqPlace)-[:contains*0..]->(c:GqPlace)-[:has_venue]->(v:GqVenue)
        WHERE s.name = 'USA' AND c.kind = 'city' AND (v.name STARTS WITH 'E' OR v.name ENDS WITH 'sh')
        RETURN v
      CYPHER
      expect(names(cypher(query))).to eq(%w[Crush Eagle])
      expect(names(cypher("MATCH (p:GqPlace) WHERE p.kind IN ['city', 'metro'] AND NOT p.name =~ 'S.*' RETURN p")))
        .to eq(['Pacific Northwest', 'Portland'])
      expect(names(cypher("MATCH (p:GqPlace) WHERE toLower(p.name) CONTAINS 'land' RETURN p"))).to eq(['Portland'])
      expect(names(cypher('MATCH (p:GqPlace) WHERE p.parent_id IS NULL RETURN p'))).to eq(['Pacific Northwest', 'USA'])
      expect(names(cypher("MATCH (p:GqPlace) WHERE p.kind = 'city' XOR p.name ENDS WITH 'e' RETURN p")))
        .to eq(['Portland'])
      expect(names(cypher("MATCH (p:GqPlace) WHERE p.kind NOT IN ['city', 'state'] RETURN p")))
        .to eq(['King County', 'Pacific Northwest', 'USA'])
    end

    it 'tests a bare property for true and takes edge property maps' do
      expect(names(cypher('MATCH (v:GqVenue)-[:hosts]->(e:GqEvent) WHERE e.cancelled RETURN v'))).to eq(['Eagle'])
      expect(names(cypher("MATCH (:GqPlace {name: 'Pacific Northwest'})-[:contains {role: 'core'}]->(c) RETURN c")))
        .to eq(['Seattle'])
    end

    it 'returns properties, counts, order, skip and limit' do
      query = "MATCH (:GqPlace {name: 'USA'})-[:contains*1..]->(c:GqPlace) WHERE c.kind = 'city' " \
              'RETURN c.name ORDER BY c.name DESC SKIP 1 LIMIT $n'
      expect(cypher(query, n: 1)).to eq(['Seattle'])
      expect(cypher("MATCH (p:GqPlace) WHERE p.kind = 'state' RETURN p.name, p.kind ORDER BY p.name"))
        .to eq([%w[Oregon state], %w[Washington state]])
      expect(cypher('MATCH (p:GqPlace) RETURN DISTINCT p.kind ORDER BY p.kind')).to eq(%w[city country county metro
                                                                                          state])
      expect(cypher('MATCH (:GqVenue)-[:hosts]->(e:GqEvent) RETURN count(*)')).to eq(4)
      expect(cypher('MATCH (v:GqVenue)-[:hosts]->(:GqEvent) RETURN count(DISTINCT v)')).to eq(3)
    end

    it 'reads comments, any keyword case, functions in ORDER BY and columns compared on one node' do
      query = <<~CYPHER
        // cities, lowest first
        match (p:GqPlace) where p.kind = 'city' and p.name <> p.kind
        return p.name order by toLower(p.name) desc limit 2;
      CYPHER
      expect(cypher(query)).to eq(%w[Spokane Seattle])
    end

    it 'joins several patterns on the variables they share' do
      query = <<~CYPHER
        MATCH (p:GqPerson)-[:billed_on]->(e:GqEvent), (v:GqVenue)-[:hosts]->(e)
        MATCH (:GqPlace {name: 'Oregon'})-[:contains*0..]->()-[:has_venue]->(v)
        RETURN e
      CYPHER
      expect(names(cypher(query))).to eq(['Drag Brunch'])
    end

    it 'says what it does not do' do
      expect { cypher('MATCH (a:GqPlace)-->(b:GqPlace) WHERE a.name = b.name RETURN a') }
        .to raise_error(GraphQuery::UnsupportedCypher, /compares a and b/)
      expect { cypher('MATCH (a:GqPlace)-->(b) RETURN a, b') }.to raise_error(GraphQuery::UnsupportedCypher)
      expect { cypher('OPTIONAL MATCH (a:GqPlace) RETURN a') }.to raise_error(GraphQuery::UnsupportedCypher)
      expect { cypher('MATCH (a:GqPlace) WHERE a.nope = 1 RETURN a') }.to raise_error(GraphQuery::UnsupportedCypher)
      expect { cypher('MATCH (a:GqPlace) RETURN a', x: 1).to_a && cypher('MATCH (a:GqPlace {name: $x}) RETURN a') }
        .to raise_error(GraphQuery::PatternError, /\$x/)
      expect { cypher('MATCH (a:GqPlace) RETRN a') }.to raise_error(GraphQuery::PatternError)
    end
  end

  describe 'computed edges' do
    it 'walks an edge built by a callable when the query runs' do
      expect(names(eagle.traverse(:same_place))).to eq(['Wildrose'])
      expect(names(GqPlace.where(id: washington).traverse(:contains, depth: 0..).traverse(:has_venue)
                          .traverse(:same_place))).to eq(%w[Eagle Wildrose])
    end
  end

  describe 'transaction' do
    let(:hill) { GqPlace.create!(name: 'Capitol Hill', kind: 'neighborhood') }

    it 'links and unlinks through every kind of edge table' do
      graph = GraphQuery.transaction do |g|
        g.link(seattle, :contains, hill, via: 'GqPlace')          # has_many: the child's parent_id
        g.link(hill, :has_venue, eagle)                           # has_many: the venue's gq_place_id
        g.link(drew, :billed_on, karaoke)                         # join row
        g.unlink(drew, :billed_on, drag_brunch)
        g.link(northwest, :contains, hill, via: GqGrouping, attributes: { role: 'nearby' })
      end
      expect(hill.reload.parent_id).to eq(seattle.id)
      expect(eagle.reload.gq_place_id).to eq(hill.id)
      expect(names(drew.traverse(:billed_on))).to eq(['Karaoke', 'Leather Night'])
      expect(GqGrouping.find_by(super_place_id: northwest.id, member_place_id: hill.id).role).to eq('nearby')
      expect(graph.changes.map(&:action)).to eq(%i[link link link unlink link])
    end

    it 'writes belongs_to edges, relinks, checks, and changes nothing that is already so' do
      GraphQuery.transaction do |g|
        g.link(hill, :within, king)
        g.relink(spokane, :has_venue, eagle, from: seattle)
        expect(g.linked?(hill, :within, king)).to be(true)
        expect(g.linked?(seattle, :has_venue, eagle)).to be(false)
        expect { g.link(spokane, :has_venue, eagle) }.not_to(change { g.changes.size })
        expect { g.unlink(drew, :billed_on, karaoke) }.not_to(change { g.changes.size })
      end
      expect(hill.reload.parent_id).to eq(king.id)
      expect(eagle.reload.gq_place_id).to eq(spokane.id)
    end

    it 'rolls every write back on an error' do
      expect do
        GraphQuery.transaction do |g|
          g.link(hill, :has_venue, eagle)
          raise 'boom'
        end
      end.to raise_error('boom')
      expect(eagle.reload.gq_place_id).to eq(seattle.id)
    end

    it 'refuses edges it cannot write or pick' do
      expect { GraphQuery.transaction { it.link(seattle, :contains, hill) } }
        .to raise_error(GraphQuery::AmbiguousResult, /via:/)
      expect { GraphQuery.transaction { it.link(eagle, :same_place, globe) } }.to raise_error(GraphQuery::NoEdges)
    end
  end

  describe 'graph_mutation' do
    let(:hill) { GqPlace.create!(name: 'Capitol Hill', kind: 'neighborhood') }

    it 'runs a decorated method in a transaction with the graph passed in' do
      expect(seattle.adopt(child: hill)).to eq(seattle)
      expect(hill.reload.parent_id).to eq(seattle.id)
      expect { spokane.take_venues(venues: [eagle, wildrose], fail: true) }.to raise_error(GraphQuery::Error)
      expect(eagle.reload.gq_place_id).to eq(seattle.id)
      expect(spokane.take_venues(venues: [eagle])).to eq(eagle)
    end

    it 'carries what GraphQL needs' do
      adopt = GqPlace.graph_mutations.fetch(:adopt)
      expect([adopt.required, adopt.keywords, adopt.takes_graph?]).to eq([[:child], [:child], true])
      take = GqPlace.graph_mutations.fetch(:take_venues)
      expect([take.required, take.keywords, take.returns]).to eq([[:venues], %i[venues fail], 'GqVenue'])
      expect([GqPlace.graph_mutations.fetch(:tidy).keywords, seattle.tidy]).to eq([[], seattle])
    end
  end

  describe 'Apache AGE' do
    it 'knows when AGE is missing' do
      expect(GraphQuery::Age.available?).to be(false)
      expect { GraphQuery::Age.cypher('g', 'MATCH (n) RETURN n') }.to raise_error(GraphQuery::Error)
    end
  end
end
