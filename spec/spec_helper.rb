# frozen_string_literal: true

# Runs the engine's specs on their own: GRAPH_QUERY_DATABASE_URL names a PostgreSQL database to make gq_ tables in.
# The host app runs the same examples (spec/graph_query in audience_kit_api).
require 'graph_query'

ActiveRecord::Base.establish_connection(ENV.fetch('GRAPH_QUERY_DATABASE_URL', 'postgres:///graph_query_test'))
require_relative 'support/graph_fixtures'
require_relative 'support/graph_query_examples'

RSpec.configure do |config|
  config.before(:suite) { GraphQuerySpec.create_tables! }
  config.after(:suite) { GraphQuerySpec.drop_tables! }
  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
