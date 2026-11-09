# typed: strict
# frozen_string_literal: true

require "tapioca/dsl"

module Tapioca
  module Compilers
    # Generates sigs for the `<attr>_enum` / `<attr>_enum=` accessors that
    # ApplicationRecord.attribute defines when given a T::Enum
    #. Nilability comes
    # from allow_nil or the column's own nullability. Never hand-write shims
    # for these — run `bin/tapioca dsl <Model>` after adding an enum attribute.
    class TypedEnumAttribute < Tapioca::Dsl::Compiler
      extend T::Sig

      ConstantType = type_member { { fixed: T.class_of(ApplicationRecord) } }

      sig { override.returns(T::Enumerable[T::Module[T.anything]]) }
      def self.gather_constants
        descendants_of(ApplicationRecord).reject(&:abstract_class?).select do |klass|
          klass.typed_enum_attributes.any?
        end
      end

      sig { override.void }
      def decorate
        attributes = constant.typed_enum_attributes
        return if attributes.empty?

        root.create_path(constant) do |model|
          attributes.each do |attribute|
            enum_name = "#{attribute.name}_enum"
            enum_type = attribute.enum.name
            nilable = attribute.allow_nil || column_nullable?(attribute.name)
            getter_type = nilable ? "T.nilable(#{enum_type})" : enum_type

            model.create_method(enum_name, return_type: getter_type)
            model.create_method(
              "#{enum_name}=",
              parameters: [ create_param("value", type: getter_type) ],
              return_type: "void"
            )
          end
        end
      end

      private

      sig { params(name: Symbol).returns(T::Boolean) }
      def column_nullable?(name)
        column = constant.columns_hash[name.to_s]
        column.nil? ? true : column.null
      rescue StandardError
        true
      end
    end
  end
end
