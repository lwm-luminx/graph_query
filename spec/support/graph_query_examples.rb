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

    it 'says which edges are missing' do
      expect { GqEvent.all.traverse(:contains).to_a }.to raise_error(GraphQuery::NoEdges, /contains/)
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
  end

  describe 'Apache AGE' do
    it 'knows when AGE is missing' do
      expect(GraphQuery::Age.available?).to be(false)
      expect { GraphQuery::Age.cypher('g', 'MATCH (n) RETURN n') }.to raise_error(GraphQuery::Error)
    end
  end
end
