# typed: strict
# frozen_string_literal: true

module Mcp
  # The tool catalog, filtered per token: what a token may not use never
  # appears in its tools/list. Every tool today only reads,
  # so every token sees all of them; a tool that changes something declares
  # `read_only? = false` and is then kept from read-scoped tokens and from
  # guests, the same line ApplicationController draws for the console API.
  module Toolbox
    extend T::Sig

    # Deterministic order: tools/list is part of every client's prompt-cache
    # prefix, and a reshuffled catalog invalidates it. New tools are
    # appended, never inserted.
    ALL = T.let([
      Mcp::Tools::Whoami,
      Mcp::Tools::ListApps,
      Mcp::Tools::DescribeData,
      Mcp::Tools::RunQuery,
      Mcp::Tools::FieldValues,
      Mcp::Tools::SlowEndpoints,
      Mcp::Tools::TopFunctions,
      Mcp::Tools::GetTrace,
      Mcp::Tools::TailLogs,
      Mcp::Tools::ListIncidents,
      Mcp::Tools::ListMonitors,
      Mcp::Tools::ListMarkers,
      Mcp::Tools::ListProcesses,
      Mcp::Tools::ModelUsage,
      Mcp::Tools::GetSession,
      Mcp::Tools::Triage
    ].freeze, T::Array[T.class_of(Mcp::Tools::Base)])

    sig { params(token: ApiToken).returns(T::Array[T.class_of(Mcp::Tools::Base)]) }
    def self.for(token)
      looking_only = token.read_only? || T.cast(token.user, User).guest?
      looking_only ? ALL.select(&:read_only?) : ALL
    end
  end
end
