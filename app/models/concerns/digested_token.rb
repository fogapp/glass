# typed: strict
# frozen_string_literal: true

# A credential whose plaintext exists once, in the response that minted it:
# only its SHA-256 digest is stored, beside
# a short prefix to recognise it by in a list. Each kind has a prefix of its
# own (`token_prefix`), so a token can never be mistaken for another kind's
# and a string that is no token of this kind is turned away unqueried.
module DigestedToken
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  include UseStamped

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    validates :token_digest, presence: true, uniqueness: true
    validates :prefix, presence: true
  end

  TOKEN_BYTES = 24
  # How much of the random part the displayed prefix keeps.
  DISPLAY_CHARS = 6

  # The one digest every stored credential is kept as — the kinds above, and
  # ApiSession's bearer token and handoff code, which carry no prefix.
  sig { params(token: String).returns(String) }
  def self.digest(token) = Digest::SHA256.hexdigest(token)

  # A fresh plaintext and the columns that remember it.
  class Minted < T::Struct
    const :token, String
    const :columns, T::Hash[Symbol, String]
  end

  # What `generate` answers: the row (persisted, or carrying the errors that
  # kept it from saving) and the plaintext, which exists only here.
  class Generated
    extend T::Sig
    extend T::Generic

    Record = type_member { { upper: ApplicationRecord } }

    sig { returns(Record) }
    attr_reader :record

    sig { returns(String) }
    attr_reader :token

    sig { params(record: Record, token: String).void }
    def initialize(record:, token:)
      @record = record
      @token = token
    end
  end

  module ClassMethods
    extend T::Sig
    extend T::Helpers
    extend T::Generic

    abstract!
    has_attached_class!(:out) { { upper: ApplicationRecord } }

    sig { abstract.returns(String) }
    def token_prefix; end

    sig { params(token: String).returns(String) }
    def digest(token) = DigestedToken.digest(token)

    sig { returns(Integer) }
    def display_prefix_length = token_prefix.length + DISPLAY_CHARS

    sig { returns(Minted) }
    def mint
      token = "#{token_prefix}#{SecureRandom.hex(TOKEN_BYTES)}"
      Minted.new(token: token, columns: { token_digest: digest(token), prefix: token.first(display_prefix_length) })
    end

    # A new row of `attributes` under a fresh token, saved — or not, when it
    # is invalid, which the caller reads off the row.
    sig { params(attributes: T.untyped).returns(Generated[T.attached_class]) }
    def generate_with(**attributes)
      minted = mint
      record = T.unsafe(self).new(**attributes, **minted.columns)
      record.save
      Generated.new(record: record, token: minted.token)
    end

    # The row in `scope` a plaintext names, or nil. The digest lookup is the
    # comparison: equal digests or no row, so there is no early-exit string
    # compare to time.
    sig { params(scope: ActiveRecord::Relation, token: T.nilable(String)).returns(T.untyped) }
    def find_by_token(scope, token)
      return nil unless token&.start_with?(token_prefix)

      scope.find_by(token_digest: digest(token))
    end
  end

  mixes_in_class_methods(ClassMethods)
end
