# frozen_string_literal: true

module GraphQuery
  # A linear Cypher-style path pattern: nodes in parentheses joined by relationships.
  #
  #   (s:Locale {name: 'Seattle'})-[:contains*0..]->(c)-[:has_venue]->(v:Venue)<-[:plays_at|hosts]-(p:Person)
  #
  # Nodes: (var), (var:Label), (:Label|Other), (), each with an optional property map ({name: 'x', kind: $kind}).
  # Relationships: -[var:name|other*min..max {prop: value}]-> (out), <-[...]- (in), -[...]- (either way), and
  # --> / <-- / -- for any edge, one hop. Lengths: * (1 or more), *2 (exactly 2), *1..3, *..3 (1 to 3), *0.. (0 or
  # more). Names may be written CONTAINS or hasVenue; they are matched as :contains and :has_venue. Labels are model
  # names. $name in a property map reads params. For WHERE, RETURN and more than one path, see GraphQuery::Cypher.
  class Pattern
    include Syntax

    Node = Data.define(:var, :labels, :props)
    Rel = Data.define(:var, :names, :direction, :min, :max, :props)

    attr_reader :nodes, :rels, :source

    def self.parse(source, params = {}) = new(source, params:)

    # With scanner:, reads one pattern from where the scanner stands and leaves it after the last node (Cypher reads
    # the rest); otherwise the whole source must be one pattern.
    def initialize(source, params: {}, scanner: nil)
      @source = source
      @params = params
      @scanner = scanner || StringScanner.new(source)
      @nodes = []
      @rels = []
      parse
      fail!('the end of the pattern') unless scanner || skip_space.eos?
    end

    # Every variable, and where it is: [:node, index] or [:rel, index].
    def variables
      vars = {}
      nodes.each_with_index { |node, i| vars[node.var] = [:node, i] if node.var }
      rels.each_with_index { |rel, i| vars[rel.var] = [:rel, i] if rel.var }
      vars
    end

    def to_s = source

    private

    def parse
      @nodes << node
      while skip_space.check(/<-|-/)
        @rels << rel
        @nodes << node
      end
    end

    def node
      expect('(')
      var = ident
      labels = nil
      labels = names_list.map(&:camelize) if skip_space.skip(/:/)
      props = skip_space.check(/\{/) ? map : nil
      expect(')')
      Node.new(var: var&.to_sym, labels:, props:)
    end

    def rel
      skip_space
      left = @scanner.scan(/<-|-/) || fail!('a relationship')
      var = names = props = nil
      min = max = 1
      if @scanner.skip(/\[/)
        var = ident&.to_sym
        names = names_list.map { it.underscore.to_sym } if skip_space.skip(/:/)
        min, max = length if skip_space.skip(/\*/)
        props = map if skip_space.check(/\{/)
        expect(']')
      end
      right = @scanner.scan(/->|-/) || fail!('the end of a relationship')
      Rel.new(var:, names:, direction: direction_of(left, right), min:, max:, props:)
    end

    def direction_of(left, right)
      return fail!('one arrow per relationship') if left == '<-' && right == '->'
      return :in if left == '<-'

      right == '->' ? :out : :both
    end

    # After *: nothing (1..), N (exactly N), N.. , ..M, N..M.
    def length
      skip_space
      first = @scanner.scan(/\d+/)&.to_i
      return [first || 1, first] unless skip_space.skip(/\.\./)

      last = skip_space.scan(/\d+/)&.to_i
      [first || 1, last]
    end

    def names_list
      list = [ident || fail!('a name')]
      list << (ident || fail!('a name')) while skip_space.skip(/\|:?/)
      list
    end
  end
end
