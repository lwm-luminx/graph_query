# frozen_string_literal: true

require 'strscan'

module GraphQuery
  # The tokens Pattern and Cypher share: whitespace, names, punctuation and literal values (strings, numbers, booleans,
  # null, lists, maps and $parameters). A class that includes it sets @scanner, @source and @params.
  module Syntax
    IDENT = /[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*/
    NUMBER = /-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?/

    private

    def skip_space
      @scanner.skip(%r{(?:\s+|//[^\n]*)+})
      @scanner
    end

    def ident = skip_space.scan(IDENT) || skip_space.scan(/`[^`]+`/)&.delete('`')

    def expect(token)
      skip_space.skip(Regexp.new(Regexp.escape(token))) || fail!("'#{token}'")
    end

    def keyword?(word) = skip_space.check(/#{word}\b/i)

    def keyword(word) = skip_space.skip(/#{word}\b/i)

    def fail!(what)
      raise PatternError, "expected #{what} at #{@scanner.pos} in #{@source.inspect}"
    end

    # A literal or a $parameter.
    def value
      skip_space
      if @scanner.skip(/\$/) then param(ident || fail!('a parameter name'))
      elsif (text = @scanner.scan(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/)) then unquote(text)
      elsif (number = @scanner.scan(NUMBER)) then number.include?('.') || number =~ /e/i ? number.to_f : number.to_i
      elsif @scanner.check(/\[/) then list
      elsif @scanner.check(/\{/) then map
      else constant
      end
    end

    def constant
      word = @scanner.scan(/(?:true|false|null)\b/i) || fail!('a value')
      { 'true' => true, 'false' => false, 'null' => nil }.fetch(word.downcase)
    end

    def param(name)
      key = name.to_sym
      return @params.fetch(key) if @params.key?(key)
      return @params.fetch(name) if @params.key?(name)

      raise PatternError, "no value given for $#{name}"
    end

    def unquote(text)
      text[1..-2].gsub(/\\(.)/) { { 'n' => "\n", 't' => "\t" }.fetch(::Regexp.last_match(1), ::Regexp.last_match(1)) }
    end

    def list
      expect('[')
      items = []
      until skip_space.skip(/\]/)
        items << value
        skip_space.skip(/,/) || (skip_space.check(/\]/) || fail!("',' or ']'"))
      end
      items
    end

    # {key: value, ...}, as a Hash with Symbol keys.
    def map
      expect('{')
      pairs = {}
      until skip_space.skip(/\}/)
        key = ident || fail!('a property name')
        expect(':')
        pairs[key.to_sym] = value
        skip_space.skip(/,/) || (skip_space.check(/\}/) || fail!("',' or '}'"))
      end
      pairs
    end
  end
end
