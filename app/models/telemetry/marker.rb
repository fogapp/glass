# typed: strict
# frozen_string_literal: true

module Telemetry
  # Something that happened at a moment and belongs on every chart: a
  # deploy, a restart, an incident, an annotation, a Glass.event.
  class Marker < TelemetryRecord
    self.table_name = "markers"
    self.primary_key = nil

    class Kind < T::Enum
      include ApplicationEnum
      enums do
        Deploy = new("deploy")
        Restart = new("restart")
        Incident = new("incident")
        Event = new("event")
        Annotation = new("annotation")
      end
    end
  end
end
