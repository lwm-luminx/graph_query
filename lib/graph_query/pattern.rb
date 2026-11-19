# frozen_string_literal: true

require 'strscan'

module GraphQuery
  # A linear Cypher-style path pattern: nodes in parentheses joined by relationships.
  #
  #   (s:Locale)-[:contains*0..]->(c)-[:has_venue]->(v:Venue)<-[:plays_at|hosts]-(p:Person)
  #
  # Nodes: (var), (var:Label), (:Label|Other), (). Relationships: -[var:name|other*min..max]-> (out), <-[...]- (in),
  # -[...]- (either way), and --> / <-- / -- for any edge, one hop. Lengths: * (1 or more), *2 (exactly 2), *1..3,
  # *..3 (1 to 3), *0.. (0 or more). Names may be written CONTAINS or hasVenue; they are matched as :contains and
  # :has_venue. Branches, properties in braces, WHERE and RETURN are not part of it: bind variables to relations
  # instead (GraphQuery.match(pattern, v: Venue.where(kind: 'bar'))).
  class Pattern
    Node = Data.define(:var, :labels)
    Rel = Data.define(:var, :names, :direction, :min, :max)

    attr_reader :nodes, :rels

    def self.parse(source) = new(source)

    def initialize(source)
      @source = source
      @scanner = StringScanner.new(source)
      @nodes = []
      @rels = []
      parse
    end

    # Every variable, and where it is: [:node, index] or [:rel, index].
    def variables
      vars = {}
      nodes.each_with_index { |node, i| vars[node.var] = [:node, i] if node.var }
      rels.each_with_index { |rel, i| vars[rel.var] = [:rel, i] if rel.var }
      vars
    end

    private

    def parse
      @nodes << node
      until skip_space.eos?
        @rels << rel
        @nodes << node
      end
    end

    def skip_space
      @scanner.skip(/\s+/)
      @scanner
    end

    def node
      expect('(')
      var = ident
      labels = nil
      labels = names_list.map(&:camelize) if skip_space.skip(/:/)
      expect(')')
      Node.new(var: var&.to_sym, labels:)
    end

    def rel
      skip_space
      left = @scanner.scan(/<-|-/) || fail!('a relationship')
      var = nil
      names = nil
      min = max = 1
      if @scanner.skip(/\[/)
        var = ident&.to_sym
        names = names_list.map { it.underscore.to_sym } if skip_space.skip(/:/)
        min, max = length if skip_space.skip(/\*/)
        expect(']')
      end
      right = @scanner.scan(/->|-/) || fail!('the end of a relationship')
      direction = direction_of(left, right)
      Rel.new(var:, names:, direction:, min:, max:)
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

    def ident = skip_space.scan(/[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*/)

    def expect(token)
      skip_space.skip(Regexp.new(Regexp.escape(token))) || fail!("'#{token}'")
    end

    def fail!(what)
      raise PatternError, "expected #{what} at #{@scanner.pos} in #{@source.inspect}"
    end
  end
end
