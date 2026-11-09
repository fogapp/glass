# typed: strict
# frozen_string_literal: true

# Request-local context. `Current.household` drives HouseholdScoped's default
# scope; `Current.user` is the signed-in person; `trace_id` threads one causal
# episode across request → jobs → activity entries.
#
# CurrentAttributes generates untyped accessors (see the tapioca-generated
# sorbet/rbi/dsl/current.rbi); ApplicationController#current_user! /
# #current_household! are the typed boundary every caller should use.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :household, :api_session, :api_token, :trace_id
end
