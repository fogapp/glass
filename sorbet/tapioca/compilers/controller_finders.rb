# typed: strict
# frozen_string_literal: true

require "tapioca/dsl"

module Tapioca
  module Compilers
    # Generates the `set_<name>` / `<name>` methods that BaseController.finds
    # defines. The reader
    # returns the record class the declaration names — `finds :want, Want`
    # reads as a Want — which BaseController#find_for checks at runtime.
    class ControllerFinders < Tapioca::Dsl::Compiler
      extend T::Sig

      ConstantType = type_member { { fixed: T.class_of(Api::V1::BaseController) } }

      sig { override.returns(T::Enumerable[T::Module[T.anything]]) }
      def self.gather_constants
        descendants_of(Api::V1::BaseController).select { |klass| klass.finders.any? }
      end

      sig { override.void }
      def decorate
        finders = constant.finders
        return if finders.empty?

        root.create_path(constant) do |controller|
          finders.each do |finder|
            controller.create_method("set_#{finder.name}", return_type: "void", visibility: RBI::Private.new)
            controller.create_method(finder.name.to_s, return_type: "::#{finder.klass.name}", visibility: RBI::Private.new)
          end
        end
      end
    end
  end
end
