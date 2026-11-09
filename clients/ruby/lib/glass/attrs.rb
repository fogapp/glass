# frozen_string_literal: true

require "json"

module Glass
  # Attribute values as the wire takes them (protocol: string → scalar):
  # numbers, booleans and nil as they are, a structure as its JSON, anything
  # else as its string — each cut to MAX_VALUE characters.
  module Attrs
    MAX_VALUE = 1_000

    def self.scalar(value)
      case value
      when Integer, Float, true, false, nil then value
      when String then cut(value)
      when Symbol then value.to_s
      when Hash, Array then cut(JSON.generate(value)) rescue cut(value.inspect)
      else cut(value.to_s)
      end
    end

    def self.cut(text)
      text.size > MAX_VALUE ? text[0, MAX_VALUE] : text
    end
    private_class_method :cut
  end
end
