# frozen_string_literal: true

require 'monitor'

module GraphQuery
  # Every edge declared so far, by node model name. A model declares its edges when it loads, so before answering
  # which edges leave or reach a node the registry loads that node's model (autoloading in development).
  class Registry
    def initialize
      @edges = {}
      @mutex = Monitor.new
    end

    # Adds an edge, or a block that builds one when a query first needs it (associations name models that may not
    # be loaded yet while the declaring model loads). key identifies the declaration, so a reload replaces it.
    def add(edge = nil, key: edge&.key, declared_by: edge&.declared_by, &builder)
      @mutex.synchronize { @edges[key] = edge || Pending.new(declared_by.to_s, builder) }
    end

    Pending = Struct.new(:declared_by, :builder)

    # Forget the edges a model declared (when it is declared again, as code reloads).
    def clear(declared_by)
      @mutex.synchronize { @edges.delete_if { |_, edge| edge.declared_by == declared_by.to_s } }
    end

    def all
      @mutex.synchronize do
        # Building one edge can load another model, which declares more: build from a snapshot.
        @edges.select { |_, edge| edge.is_a?(Pending) }.each do |key, pending|
          @edges[key] = pending.builder.call if @edges[key].equal?(pending)
        end
        @edges.values
      end
    end

    # Edges named any of names (nil: any name) walked in a direction from nodes of these types:
    # [[edge, direction], ...]. Direction :both gives each edge both ways.
    def walkable(types, names, direction)
      types.each { load_model(it) }
      directions = direction == :both ? %i[out in] : [direction]
      directions.flat_map do |dir|
        matching = all.select do |edge|
          (names.nil? || names.include?(edge.name)) && types.include?(dir == :in ? edge.to : edge.from)
        end
        matching.map { [it, dir] }
      end
    end

    def load_model(name) = name.to_s.safe_constantize
  end
end
