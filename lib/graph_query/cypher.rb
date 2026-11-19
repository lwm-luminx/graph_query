# frozen_string_literal: true

module GraphQuery
  # A read-only Cypher query, run on the CTE walker:
  #
  #   GraphQuery.cypher(<<~CYPHER, state: 'Washington')
  #     MATCH (s:Locale {name: $state})-[:contains*0..]->()-[:has_venue]->(v:Venue)
  #     WHERE v.name STARTS WITH 'The' AND NOT v.closed
  #     RETURN v ORDER BY v.name LIMIT 10
  #   CYPHER
  #
  # Clauses: MATCH (one or more linear patterns, comma-separated or in several MATCH clauses, joined on the variables
  # they share), WHERE, RETURN [DISTINCT], ORDER BY, SKIP, LIMIT. WHERE takes =, <>, !=, <, <=, >, >=, IS [NOT] NULL,
  # IN [...], STARTS WITH, ENDS WITH, CONTAINS, =~, AND, OR, XOR, NOT, parentheses, toLower() / toUpper(), $params,
  # and a bare property (v.active) as a test for true. Each condition compares properties of one variable: a condition
  # that compares two variables raises UnsupportedCypher.
  #
  # RETURN v gives a relation of v's nodes; RETURN v.name, v.kind gives pluck's rows; RETURN count(v) or count(*)
  # an Integer. One variable per RETURN: walks find nodes, not rows of combinations.
  class Cypher
    include Syntax

    Prop = Data.define(:var, :name, :func)
    Lit = Data.define(:value)
    Cmp = Data.define(:op, :left, :right)
    Logic = Data.define(:op, :terms)
    Negation = Data.define(:term)
    Item = Data.define(:var, :prop, :count, :alias_name)
    Order = Data.define(:prop, :direction)

    COMPARISONS = { '=' => :eq, '<>' => :not_eq, '!=' => :not_eq, '<=' => :lteq, '>=' => :gteq, '<' => :lt,
                    '>' => :gt }.freeze
    FLIPPED = { eq: :eq, not_eq: :not_eq, lteq: :gteq, gteq: :lteq, lt: :gt, gt: :lt }.freeze
    FUNCTIONS = { 'tolower' => 'LOWER', 'toupper' => 'UPPER' }.freeze
    TEXT_OPERATORS = /STARTS\s+WITH\b|ENDS\s+WITH\b|CONTAINS\b|=~/i
    TEXT_TESTS = { 'STARTS WITH' => :starts_with, 'ENDS WITH' => :ends_with, 'CONTAINS' => :contains,
                   '=~' => :regexp }.freeze

    attr_reader :patterns, :where, :items, :distinct, :orders, :skip, :limit

    def initialize(source, params = {})
      @source = source
      @params = params.transform_keys(&:to_sym)
      @scanner = StringScanner.new(source)
      @patterns = []
      @conditions = []
      parse
    end

    # What the query returns: a relation, pluck's rows or a count (see the class comment).
    def result
      var = returned_var
      relation = nodes(var)
      return relation.count if items.any?(&:count)

      relation = relation.reorder(orders.map { order_node(var, it) }) if orders.any?
      relation = relation.offset(skip) if skip
      relation = relation.limit(limit) if limit
      columns = items.filter_map(&:prop)
      return relation if columns.empty?

      relation = relation.distinct if distinct
      relation.pluck(*columns.map { column(var, it) })
    end

    # The nodes a node variable matches across every pattern and the WHERE clause, as a relation.
    def nodes(var)
      bindings = where_bindings
      (patterns.size - 1).times { join_patterns(bindings) }
      pattern = patterns.find { it.variables[var]&.first == :node } || raise(PatternError, "#{var} is not in MATCH")
      match_for(pattern, bindings).nodes(var)
    end

    private

    # -- reading

    def parse
      match_clauses
      fail!('MATCH') if @patterns.empty?
      return_clause
      skip_space.skip(/;/)
      fail!('the end of the query') unless skip_space.eos?
      @where = @conditions.size > 1 ? Logic.new(op: :and, terms: @conditions) : @conditions.first
    end

    def match_clauses
      loop do
        raise UnsupportedCypher, 'OPTIONAL MATCH is not supported' if keyword?('OPTIONAL')
        break unless keyword('MATCH')

        @patterns << pattern
        @patterns << pattern while skip_space.skip(/,/)
        @conditions << expression if keyword('WHERE')
      end
    end

    def return_clause
      keyword('RETURN') || fail!('RETURN')
      @distinct = !keyword('DISTINCT').nil?
      @items = [item]
      @items << item while skip_space.skip(/,/)
      @orders = skip_space.skip(/ORDER\s+BY\b/i) ? orders_list : []
      @skip = count_value if keyword('SKIP')
      @limit = count_value if keyword('LIMIT')
    end

    def pattern
      skip_space
      Pattern.new(@source, params: @params, scanner: @scanner)
    end

    def expression = logic(:or) { logic(:xor) { logic(:and) { negation } } }

    def logic(word, &term)
      terms = [term.call]
      terms << term.call while keyword(word.to_s.upcase)
      terms.size == 1 ? terms.first : Logic.new(op: word, terms:)
    end

    def negation = keyword('NOT') ? Negation.new(term: negation) : predicate

    def predicate
      return grouped if skip_space.skip(/\(/)

      left = operand
      null_test(left) || in_test(left) || text_test(left) || comparison_test(left) || truth_test(left)
    end

    def grouped
      inner = expression
      expect(')')
      inner
    end

    # x IS NULL, x IS NOT NULL
    def null_test(left)
      return unless keyword('IS')

      negated = keyword('NOT')
      keyword('NULL') || fail!('NULL')
      test = Cmp.new(op: :eq, left:, right: Lit.new(value: nil))
      negated ? Negation.new(term: test) : test
    end

    # x IN [...], x NOT IN [...]
    def in_test(left)
      negated = skip_space.skip(/NOT\s+IN\b/i)
      return unless negated || keyword('IN')

      test = Cmp.new(op: :in, left:, right: Lit.new(value: Array(value)))
      negated ? Negation.new(term: test) : test
    end

    def text_test(left)
      word = skip_space.scan(TEXT_OPERATORS) or return
      Cmp.new(op: TEXT_TESTS.fetch(word.upcase.squeeze(' ').gsub(/\s+/, ' ')), left:, right: operand)
    end

    def comparison_test(left)
      operator = skip_space.scan(/<>|!=|<=|>=|=|<|>/) or return
      Cmp.new(op: COMPARISONS.fetch(operator), left:, right: operand)
    end

    # A bare property is a test for true.
    def truth_test(left)
      raise UnsupportedCypher, "#{left.inspect} isn't a condition" unless left.is_a?(Prop)

      Cmp.new(op: :eq, left:, right: Lit.new(value: true))
    end

    # v.prop, toLower(v.prop), or a value.
    def operand
      skip_space
      if (name = @scanner.check(/[A-Za-z_]\w*(?=\s*\()/)) && FUNCTIONS.key?(name.downcase)
        @scanner.skip(/[A-Za-z_]\w*\s*\(/)
        inner = operand
        expect(')')
        raise UnsupportedCypher, "#{name}() takes a property" unless inner.is_a?(Prop)

        return inner.with(func: FUNCTIONS.fetch(name.downcase))
      end
      if (var = @scanner.check(/[A-Za-z_]\w*(?=\.)/)) && !@scanner.check(/\d/)
        @scanner.skip(/[A-Za-z_]\w*\./)
        return Prop.new(var: var.to_sym, name: ident || fail!('a property name'), func: nil)
      end

      Lit.new(value:)
    end

    def item
      if keyword('count')
        expect('(')
        keyword('DISTINCT')
        var = skip_space.skip(/\*/) ? nil : (ident || fail!('a variable or *')).to_sym
        expect(')')
        return Item.new(var:, prop: nil, count: true, alias_name: alias_name)
      end

      var = (ident || fail!('a variable')).to_sym
      prop = skip_space.skip(/\./) ? (ident || fail!('a property name')) : nil
      Item.new(var:, prop:, count: false, alias_name: alias_name)
    end

    def alias_name = keyword('AS') ? ident : nil

    def orders_list
      list = [order]
      list << order while skip_space.skip(/,/)
      list
    end

    def order
      prop = operand
      raise UnsupportedCypher, 'ORDER BY takes properties (v.name)' unless prop.is_a?(Prop)

      direction = keyword('DESCENDING') || keyword('DESC') ? :desc : (keyword('ASCENDING') || keyword('ASC')) && :asc
      Order.new(prop:, direction: direction || :asc)
    end

    def count_value
      count = value
      raise PatternError, "SKIP and LIMIT take a whole number, not #{count.inspect}" unless count.is_a?(Integer)

      count
    end

    # -- running

    def returned_var
      vars = items.filter_map(&:var).uniq
      vars = [last_var] if vars.empty?
      raise UnsupportedCypher, "RETURN one variable, not #{vars.join(', ')}" unless vars.size == 1
      raise UnsupportedCypher, 'RETURN a node variable' unless node_vars.include?(vars.first)
      if (other = orders.map { it.prop.var }.find { it != vars.first })
        raise UnsupportedCypher, "ORDER BY #{other} when RETURN gives #{vars.first}"
      end

      vars.first
    end

    def last_var = patterns.last.nodes.last.var || raise(UnsupportedCypher, 'count(*) needs the last node named')

    def node_vars = patterns.flat_map { |pattern| pattern.nodes.filter_map(&:var) }.uniq

    # One relation per variable the WHERE clause tests, from its conditions.
    def where_bindings
      conjuncts(where).group_by { vars_of(it) }.each_with_object({}) do |(vars, terms), bindings|
        raise UnsupportedCypher, 'a condition must test a property' if vars.empty?
        raise UnsupportedCypher, "a condition compares #{vars.join(' and ')}; compare one variable" if vars.size > 1

        var = vars.first
        model = model_for(var)
        bindings[var] = model.where(terms.map { arel(model, it) }.reduce { |all, one| all.and(one) })
      end
    end

    def conjuncts(term)
      return [] if term.nil?
      return term.terms.flat_map { conjuncts(it) } if term.is_a?(Logic) && term.op == :and

      [term]
    end

    def vars_of(term)
      case term
      when Prop then [term.var]
      when Cmp then (vars_of(term.left) + vars_of(term.right)).uniq
      when Logic then term.terms.flat_map { vars_of(it) }.uniq
      when Negation then vars_of(term.term)
      else []
      end
    end

    # The model a node variable's rows come from: its one label, or the one model the walk reaches there.
    def model_for(var)
      patterns.each do |pattern|
        kind, index = pattern.variables[var]
        next unless kind == :node

        labels = pattern.nodes[index].labels
        return labels.first.constantize if labels&.size == 1

        types = Match.new(pattern, {}).query(index).types
        return types.first.constantize if types.size == 1

        raise UnsupportedCypher, "(#{var}) can be #{types.join(' or ')}: give it a label"
      end
      raise PatternError, "#{var} is not a node in MATCH"
    end

    # Narrow the variables patterns share: each pattern keeps a shared variable's nodes to those it matches.
    def join_patterns(bindings)
      counts = patterns.flat_map { |pattern| pattern.variables.select { _2.first == :node }.keys }.tally
      patterns.each do |pattern|
        shared = pattern.variables.select { |var, (kind, _)| kind == :node && counts[var] > 1 }.keys
        next if shared.empty? || patterns.size == 1

        match = match_for(pattern, bindings)
        shared.each do |var|
          found = match.nodes(var)
          model = found.klass
          bindings[var] = (bindings[var] || model.all).where(model.primary_key => found.select(model.primary_key))
        end
      end
    end

    def match_for(pattern, bindings) = Match.new(pattern, bindings.slice(*pattern.variables.keys))

    def arel(model, term)
      case term
      when Logic
        nodes = term.terms.map { arel(model, it) }
        case term.op
        when :and then Arel::Nodes::Grouping.new(Arel::Nodes::And.new(nodes))
        when :or then nodes.reduce { |any, one| any.or(one) }
        else Arel::Nodes::Grouping.new(nodes.reduce { |left, right| xor(left, right) })
        end
      when Negation then Arel::Nodes::Not.new(arel(model, term.term))
      when Cmp then comparison(model, term)
      else raise UnsupportedCypher, "#{term.inspect} isn't a condition"
      end
    end

    def xor(left, right)
      Arel::Nodes::InfixOperation.new('<>', Arel::Nodes::Grouping.new(left), Arel::Nodes::Grouping.new(right))
    end

    def comparison(model, cmp)
      left = cmp.left
      right = cmp.right
      op = cmp.op
      left, right, op = right, left, FLIPPED.fetch(op) if left.is_a?(Lit) && FLIPPED.key?(op)
      raise UnsupportedCypher, 'a condition must test a property' unless left.is_a?(Prop)

      attribute = attribute(model, left)
      other = right.is_a?(Prop) ? attribute(model, right) : right.value
      case op
      when :eq, :not_eq then equality(attribute, op, other)
      when :in then attribute.in(other)
      when :starts_with then like(attribute, other, '%s%%')
      when :ends_with then like(attribute, other, '%%%s')
      when :contains then like(attribute, other, '%%%s%%')
      when :regexp then Arel::Nodes::Regexp.new(attribute, Arel::Nodes.build_quoted("^(?:#{other})$"))
      else attribute.public_send(op, other)
      end
    end

    def equality(attribute, operator, other)
      return attribute.public_send(operator, other) unless other.nil?

      operator == :eq ? attribute.eq(nil) : attribute.not_eq(nil)
    end

    def like(attribute, text, shape)
      raise UnsupportedCypher, 'STARTS WITH, ENDS WITH and CONTAINS take a string' unless text.is_a?(String)

      attribute.matches(format(shape, ActiveRecord::Base.sanitize_sql_like(text)), '\\', true)
    end

    def attribute(model, prop)
      model.columns_hash.key?(prop.name) || raise(UnsupportedCypher, "#{model.name} has no property #{prop.name}")
      attribute = model.arel_table[prop.name]
      prop.func ? Arel::Nodes::NamedFunction.new(prop.func, [attribute]) : attribute
    end

    def column(var, name)
      model = model_for(var)
      model.columns_hash.key?(name) || raise(UnsupportedCypher, "#{model.name} has no property #{name}")
      model.arel_table[name]
    end

    def order_node(var, order)
      node = attribute(model_for(var), order.prop)
      order.direction == :desc ? node.desc : node.asc
    end
  end
end
