# frozen_string_literal: true

# A small graph for the specs, in its own gq_ tables so it can sit beside a host app's schema: places nest
# (parent_id) and group (gq_groupings), venues sit in places, events at venues, people are billed on events, links
# point at anything.
module GraphQuerySpec
  TABLES = %i[gq_links gq_billings gq_events gq_venues gq_groupings gq_places gq_people].freeze

  module_function

  def create_tables!
    ActiveRecord::Migration.suppress_messages { ActiveRecord::Schema.define { GraphQuerySpec.define_tables(self) } }
  end

  def drop_tables!
    TABLES.each { ActiveRecord::Base.connection.drop_table(it, if_exists: true) }
  end

  def define_tables(schema)
    TABLES.each { schema.drop_table(it, if_exists: true) }
    schema.create_table(:gq_places, id: :uuid) do |t|
      t.string :name, null: false
      t.string :kind
      t.uuid :parent_id, index: true
    end
    schema.create_table(:gq_groupings, id: :uuid) do |t|
      t.uuid :super_place_id, null: false, index: true
      t.uuid :member_place_id, null: false, index: true
      t.string :role
    end
    schema.create_table(:gq_venues, id: :uuid) do |t|
      t.string :name, null: false
      t.uuid :gq_place_id, index: true
    end
    schema.create_table(:gq_events, id: :uuid) do |t|
      t.string :name, null: false
      t.uuid :gq_venue_id, index: true
      t.boolean :cancelled, null: false, default: false
    end
    schema.create_table(:gq_people, id: :uuid) { |t| t.string :name, null: false }
    schema.create_table(:gq_billings, id: :uuid) do |t|
      t.uuid :gq_event_id, null: false, index: true
      t.uuid :gq_person_id, null: false, index: true
    end
    schema.create_table(:gq_links, id: :uuid) do |t|
      t.string :title
      t.string :target_type
      t.uuid :target_id
    end
  end
end

class GqGrouping < ActiveRecord::Base; end

class GqPlace < ActiveRecord::Base
  belongs_to :parent, class_name: 'GqPlace', optional: true
  has_many :children, class_name: 'GqPlace', foreign_key: :parent_id, inverse_of: :parent, dependent: nil
  has_many :gq_venues, dependent: nil

  graph_edge :contains, association: :children
  graph_edge :contains, to: GqPlace, through: GqGrouping, source: :super_place_id, target: :member_place_id
  graph_edge :within, association: :parent
  graph_edge :has_venue, association: :gq_venues
  graph_edge :rolls_up, association: :gq_venues

  graph_mutation arguments: { child: GqPlace }, description: 'Files a place under this one.'
  def adopt(child:, graph:)
    graph.link(self, :contains, child, via: 'GqPlace')
    self
  end

  graph_mutation def tidy = touch && self

  graph_mutation arguments: { venues: ['GqVenue'], fail: :boolean }, returns: 'GqVenue'
  def take_venues(venues:, graph:, fail: false)
    venues.each { graph.link(self, :has_venue, it) }
    raise GraphQuery::Error, 'asked to fail' if fail

    venues.first
  end
end

class GqVenue < ActiveRecord::Base
  belongs_to :gq_place, optional: true
  has_many :gq_events, dependent: nil
  has_many :live_events, -> { where(cancelled: false).order(:name) }, class_name: 'GqEvent', dependent: nil

  graph_edge :hosts, association: :gq_events
  graph_edge :hosts_live, association: :live_events
  graph_edge :rolls_up, association: :gq_events
  graph_edge(:same_place, to: GqVenue) do
    GqVenue.joins('JOIN gq_venues other ON other.gq_place_id = gq_venues.gq_place_id AND other.id <> gq_venues.id')
           .select('gq_venues.id AS source_id, other.id AS target_id')
  end
end

class GqEvent < ActiveRecord::Base
  belongs_to :gq_venue, optional: true
  has_many :gq_billings, dependent: nil
  has_many :gq_people, through: :gq_billings
end

class GqBilling < ActiveRecord::Base
  belongs_to :gq_event
  belongs_to :gq_person
end

class GqPerson < ActiveRecord::Base
  self.table_name = 'gq_people'
  has_many :gq_billings, dependent: nil
  has_many :gq_events, through: :gq_billings

  graph_edge :billed_on, association: :gq_events
  graph_edge :rolls_up, association: :gq_events
end

class GqLink < ActiveRecord::Base
  belongs_to :target, polymorphic: true, optional: true
end
