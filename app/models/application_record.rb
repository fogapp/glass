# typed: strict
# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  extend T::Sig

  primary_abstract_class

  # Registry of enum-typed attributes, read by the tapioca compiler
  # (sorbet/tapioca/compilers/typed_enum_attribute.rb) to generate sigs for
  # the *_enum accessors.
  TypedEnumAttribute = Struct.new(:name, :enum, :allow_nil)

  class_attribute :typed_enum_attributes, instance_accessor: false, default: []

  class << self
    extend T::Sig

    # `attribute :kind, SomeEnum` wires a closed vocabulary onto a plain string
    # column: inclusion validation from the enum's own values, plus typed
    # `kind_enum` / `kind_enum=` accessors. Columns stay strings on disk for
    # greppability; never hand-roll `validates :x, inclusion:` for a closed set.
    sig do
      params(name: T.any(Symbol, String), type: T.untyped, options: T.untyped).void
    end
    def attribute(name, type = nil, **options)
      if type.is_a?(Class) && type < T::Enum
        enum_class = type
        allow_nil = options.delete(:allow_nil) ? true : false
        self.typed_enum_attributes += [ TypedEnumAttribute.new(name.to_sym, enum_class, allow_nil) ]
        validates name, inclusion: { in: enum_class.values.map(&:serialize) }, allow_nil: allow_nil

        define_method(:"#{name}_enum") do
          raw = public_send(name)
          raw.nil? ? nil : enum_class.try_deserialize(raw)
        end
        define_method(:"#{name}_enum=") do |value|
          public_send(:"#{name}=", value.nil? ? nil : T.cast(value, T::Enum).serialize)
        end
        super(name, :string, **options)
      else
        type.nil? ? super(name, **options) : super
      end
    end
  end

  # Stamps `column` with `now` unless it already says a time within `every`
  # of it — for rows read on a hot path (every request, every batch) that
  # must not be written on every one. `also` rides along on the same write.
  # Answers whether it wrote.
  sig do
    params(
      column: Symbol, every: ActiveSupport::Duration, now: T.any(Time, ActiveSupport::TimeWithZone),
      also: T::Hash[Symbol, T.untyped]
    ).returns(T::Boolean)
  end
  def stamp_throttled!(column, every:, now: Time.current, also: {})
    last = self[column]
    return false if last && last > now - every

    update_columns(also.merge(column => now)) # rubocop:disable Rails/SkipsModelValidations
    true
  end
end
