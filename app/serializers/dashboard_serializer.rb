# typed: strict
# frozen_string_literal: true

module DashboardSerializer
  extend T::Sig

  sig { params(dashboard: Dashboard).returns(T::Hash[Symbol, T.untyped]) }
  def self.dashboard_json(dashboard)
    # Read through the model, so a widget saved before it had a kind or
    # labels answers with what it would be saved as now.
    widgets = dashboard.widgets.filter_map { |widget| Dashboard.widget_from(widget) }
    { id: dashboard.id, name: dashboard.name, description: dashboard.description, widgets: widgets,
      position: dashboard.position, updated_at: dashboard.updated_at }
  end
end
