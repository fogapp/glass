# typed: strict
# frozen_string_literal: true

# The one read path over telemetry. A query names a source,
# a time range, a filter, what to compute and how to group it; the engine
# compiles that to SQL against a registry of allow-listed columns and
# answers in the shape a chart or table draws directly.
#
# There is no raw-SQL surface. Identifiers only ever come from the registry
# (Query::Sources); everything a person typed is a bound parameter.
module Query
  # A query that cannot be compiled: an unknown source, column or function,
  # a malformed filter, a range that makes no sense. The message is written
  # for the person who typed the query — it is rendered to them as is.
  class Invalid < StandardError; end
end
