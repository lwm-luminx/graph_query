# frozen_string_literal: true

module GraphQuery
  # Apache AGE, when the database has it: real Cypher over a graph AGE stores itself. Heroku Postgres (and most
  # hosted Postgres) doesn't offer AGE, so Query's recursive CTEs over your own tables are the default and need
  # nothing installed; this is a pass-through for databases that do have it.
  module Age
    module_function

    def available?(connection = ActiveRecord::Base.connection)
      connection.select_value("SELECT 1 FROM pg_extension WHERE extname = 'age'").present?
    end

    # Runs a Cypher query in an AGE graph and returns its rows (agtype values as text), one column per name in
    # columns.
    def cypher(graph, query, columns: [:result], connection: ActiveRecord::Base.connection)
      raise Error, 'Apache AGE is not installed in this database' unless available?(connection)

      tag = '$graph_query$'
      raise ArgumentError, "the query can't contain #{tag}" if query.include?(tag)

      list = columns.map { "#{connection.quote_column_name(it)} agtype" }.join(', ')
      connection.transaction(requires_new: true) do
        connection.execute("LOAD 'age'")
        connection.execute('SET LOCAL search_path = ag_catalog, "$user", public')
        name = connection.quote(graph.to_s)
        connection.select_rows("SELECT * FROM cypher(#{name}, #{tag}#{query}#{tag}) AS (#{list})")
      end
    end
  end
end
