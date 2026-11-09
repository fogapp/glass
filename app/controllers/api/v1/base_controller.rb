# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # House controller base.
    # Controllers stay thin: params in, service/serializer out. Use these
    # helpers instead of re-rolling them — cop-enforced where possible.
    class BaseController < ApplicationController
      extend T::Sig

      # The rescue table (each of these is a 500 unless rescued explicitly):
      # - ParameterMissing descends from KeyError, not BadRequest → explicit 400
      # - RecordNotUnique on double-submit → 409, not 500
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from ActionController::ParameterMissing, with: :render_missing_parameter
      rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict
      # A validation failure is the person's to fix: the record's own
      # messages, 422 — what every create and update rescued by hand before.
      rescue_from ActiveRecord::RecordInvalid, with: :render_invalid
      # A query the Explorer could not compile (unknown source, column or
      # function, a range too wide) is the asker's to fix — 422 with the
      # compiler's own sentence.
      rescue_from Query::Invalid, with: :render_invalid_query

      # Guests are read-only (ACCESS.md › Roles). Controllers where a guest
      # manages only their own sign-in skip this.
      before_action :deny_guest_writes

      # One `finds` declaration: the reader's name, the record class it
      # answers (the tapioca compiler types the reader with it), the param
      # that carries the id, and the scope to look in — nil for `klass.all`.
      class Finder < T::Struct
        const :name, Symbol
        const :klass, T.class_of(ApplicationRecord)
        const :param, Symbol
        # Unbound here only because Sorbet allows `bind` on block params
        # alone; `finds` takes it bound to the controller, and find_for
        # instance_execs it on one.
        const :scope, T.nilable(T.proc.returns(ActiveRecord::Relation))
      end

      class_attribute :finders, instance_accessor: false, default: T.let([].freeze, T::Array[Finder])

      class << self
        extend T::Sig

        # `finds :source, Source` defines a before_action `set_source` and a
        # private `source` reader typed as Source (the finders registry feeds
        # sorbet/tapioca/compilers/controller_finders.rb) — replaces the
        # @ivar + T.must ceremony. A block narrows where the record is looked
        # for; it runs on the controller, so it may call private helpers:
        #
        #   finds(:api_token, ApiToken) { current_user!.api_tokens }
        sig do
          params(
            name: Symbol,
            klass: T.class_of(ApplicationRecord),
            param: Symbol,
            scope: T.nilable(T.proc.bind(BaseController).returns(ActiveRecord::Relation))
          ).void
        end
        def finds(name, klass, param: :id, &scope)
          finder = Finder.new(name: name, klass: klass, param: param, scope: scope)
          self.finders = [ *finders, finder ].freeze
          ivar = :"@#{name}"

          define_method(:"set_#{name}") do
            T.bind(self, BaseController)
            instance_variable_set(ivar, find_for(finder))
          end
          private :"set_#{name}"

          define_method(name) do
            unless instance_variable_defined?(ivar)
              raise "#{name} accessed before set_#{name} ran — add `before_action :set_#{name}`"
            end
            instance_variable_get(ivar)
          end
          private name

          before_action :"set_#{name}"
        end
      end

      private

      # The record a `finds` declaration names, from its scope. The reader's
      # generated sig promises finder.klass, so a scope that answers anything
      # else is a programming error, raised here rather than later.
      sig { params(finder: Finder).returns(ApplicationRecord) }
      def find_for(finder)
        scope = finder.scope
        relation = T.let(scope ? instance_exec(&scope) : finder.klass.all, ActiveRecord::Relation)
        record = relation.find(params.require(finder.param))
        return record if record.is_a?(finder.klass)

        raise TypeError, "finds :#{finder.name} expected #{finder.klass}, got #{record.class}"
      end

      # Accepts the optional exception because sorbet-runtime sig wrappers
      # report arity -1, which makes Rails' rescue_from pass the exception
      # even to handlers declared with zero params.
      sig { params(_exception: T.untyped).void }
      def render_not_found(_exception = nil)
        render_errors("Not found", status: :not_found)
      end

      sig { params(exception: ActionController::ParameterMissing).void }
      def render_missing_parameter(exception)
        render_errors("Missing parameter: #{exception.param}", status: :bad_request)
      end

      sig { params(_exception: T.untyped).void }
      def render_conflict(_exception = nil)
        render_errors("That already exists", status: :conflict)
      end

      sig { params(exception: ActiveRecord::RecordInvalid).void }
      def render_invalid(exception)
        render_errors(exception.record || exception.message)
      end

      sig { params(exception: Query::Invalid).void }
      def render_invalid_query(exception)
        render_errors(exception.message)
      end

      # The `from`/`to` of a read, as [from, to], read the one way every
      # endpoint reads them (Query::Bounds): Unix seconds as the console
      # sends them, ISO 8601, "-15m", "now". Absent (or blank) bounds fall
      # back to `default` before now; with no default both are required.
      # Garbage, a range that ends before it starts, or one wider than `max`
      # raises Query::Invalid — a 422 naming what to fix. `source` is the
      # params (or a nested hash of them) the bounds are read from.
      sig do
        params(
          source: T.untyped, default: T.nilable(ActiveSupport::Duration), max: ActiveSupport::Duration
        ).returns([ Time, Time ])
      end
      def range_param(source = params, default: 1.day, max: Query::Request::MAX_RANGE)
        Query::Bounds.resolve(from: source[:from].presence, to: source[:to].presence, default: default, max: max)
      end

      # A Settings "Test" button's answer: { ok:, message: } — the one shape
      # outside the { errors: } envelope, because a failed test is a result
      # to show, not a request that went wrong. The block runs the test and
      # answers [ok, message]; an upstream error it lets out is a failed
      # test with that error's message. `tested:` (AppSetting#record_test!) keeps
      # the outcome on the row, in the columns `prefix` names. Answers
      # whether the test passed.
      sig do
        params(
          tested: T.nilable(AppSetting),
          prefix: String,
          blk: T.proc.returns([ T::Boolean, String ])
        ).returns(T::Boolean)
      end
      def render_connection_test(tested: nil, prefix: "", &blk)
        ok, message = begin
          yield
        rescue UpstreamHttpClient::Error => e
          [ false, e.message ]
        end
        tested&.record_test!(ok, message, prefix: prefix)
        render json: { ok: ok, message: message }
        ok
      end

      # Offset pagination for list screens: response stays a bare array,
      # totals ride in headers (the client reads X-Total-Count).
      # The merged-timeline endpoints use cursor pagination instead.
      #
      # The total is for pagers, not analytics: it counts at most COUNT_CAP
      # rows (X-Total-Count-Capped says when it hit the ceiling), because an
      # exact COUNT(*) per page view grows with the install's age rather
      # than with the page.
      COUNT_CAP = 10_000

      # Generic over the relation, so a page of apps still reads as apps to
      # Sorbet — offset/limit answer the receiver's own class.
      sig do
        type_parameters(:R)
          .params(scope: T.all(ActiveRecord::Relation, T.type_parameter(:R)), default_per: Integer, max_per: Integer)
          .returns(T.type_parameter(:R))
      end
      def paginate(scope, default_per: 100, max_per: 500)
        page = params[:page].to_i.clamp(1, 1_000_000)
        per = (params[:per].presence&.to_i || default_per).clamp(1, max_per)
        total = scope.limit(COUNT_CAP).count
        response.set_header("X-Total-Count", total.to_s)
        response.set_header("X-Total-Count-Capped", "true") if total >= COUNT_CAP
        response.set_header("X-Page", page.to_s)
        response.set_header("X-Per-Page", per.to_s)
        T.cast(scope.offset((page - 1) * per).limit(per), T.type_parameter(:R))
      end

      sig { params(key: T.any(Symbol, String), default: T::Boolean).returns(T::Boolean) }
      def bool_param(key, default: false)
        raw = params[key]
        return default if raw.nil?

        ActiveModel::Type::Boolean.new.cast(raw) ? true : false
      end

      # Anything but a read, from a guest, is refused. Requests with no
      # signed-in user (setup, sign-in, invite acceptance) are not a guest's.
      sig { void }
      def deny_guest_writes
        return if request.get? || request.head?

        user = Current.user
        return unless user.is_a?(User) && user.guest?

        render_errors("Guests have read-only access", status: :forbidden)
      end

      sig { void }
      def require_admin!
        return if current_user!.admin?

        render_errors("Admin access required", status: :forbidden)
      end
    end
  end
end
