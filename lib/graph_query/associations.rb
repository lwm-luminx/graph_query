# frozen_string_literal: true

module GraphQuery
  # Turns an association into an Edge, so a graph edge is declared by naming an association the model already has.
  module Associations
    module_function

    def edge_for(owner, name, reflection, where: nil)
      if reflection.polymorphic?
        raise ArgumentError,
              "#{owner.name}.#{reflection.name} is polymorphic, so it has no one node type"
      end

      if reflection.through_reflection?
        through_edge(owner, name, reflection,
                     where)
      else
        direct_edge(owner, name, reflection, where)
      end
    end

    # belongs_to: the owner's row points at the target. has_many / has_one: the target's row points at the owner
    # (and, with as:, names the owner's type).
    def direct_edge(owner, name, reflection, where)
      target = reflection.klass
      if reflection.belongs_to?
        Edge.new(name:, from: owner.polymorphic_name, to: target.polymorphic_name, declared_by: owner.name,
                 table_model: owner.name, source_column: owner.primary_key, target_column: reflection.foreign_key,
                 conditions: [where])
      else
        conditions = [scope_of(reflection), where]
        conditions << { reflection.type => owner.polymorphic_name } if reflection.type
        Edge.new(name:, from: owner.polymorphic_name, to: target.polymorphic_name, declared_by: owner.name,
                 table_model: target.name, source_column: reflection.foreign_key,
                 target_column: target.primary_key, conditions:)
      end
    end

    # has_many :through one join model, which belongs_to the target: each join row is an edge.
    def through_edge(owner, name, reflection, where)
      through = reflection.through_reflection
      source = reflection.source_reflection
      unless !through.through_reflection? && !through.belongs_to? && source.belongs_to? && !source.polymorphic?
        raise ArgumentError, "#{owner.name}.#{reflection.name}: only has_many :through a join model that " \
                             'belongs_to the target can be an edge; name the join model with through: instead'
      end

      if reflection.scope
        raise ArgumentError, "#{owner.name}.#{reflection.name}: a :through association's own scope filters the " \
                             'target, not the join rows; declare the edge with through: and where: instead'
      end

      conditions = [scope_of(through), where]
      conditions << { through.type => owner.polymorphic_name } if through.type
      Edge.new(name:, from: owner.polymorphic_name, to: reflection.klass.polymorphic_name, declared_by: owner.name,
               table_model: through.klass.name, source_column: through.foreign_key,
               target_column: source.foreign_key, conditions:)
    end

    # The association's own scope, when it filters the rows that hold the edge (has_many's target, or the join
    # model). Ordering is dropped; scopes that take the owner can't be walked.
    def scope_of(reflection)
      scope = reflection.scope
      return nil if scope.nil?
      if scope.arity.positive?
        raise ArgumentError,
              "#{reflection.name}: scopes that take the owner record can't be walked"
      end

      scope
    end
  end
end
