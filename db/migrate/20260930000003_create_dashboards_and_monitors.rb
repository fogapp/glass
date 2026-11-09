# frozen_string_literal: true

# Saved questions: a dashboard is a grid of them, a
# monitor is one with a condition. All three are the same query object.
class CreateDashboardsAndMonitors < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboards, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      # [{ id, title, spec: { source, filter, compute, group_by, shape, metric, field }, span: 1..3, height }]
      t.jsonb :widgets, null: false, default: []
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :monitors, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      t.boolean :enabled, null: false, default: true
      # threshold | absence
      t.string :kind, null: false, default: "threshold"
      # The Explorer query that produces the value: source, filter, compute (one), metric.
      t.jsonb :query, null: false, default: {}
      # gt | lt
      t.string :comparison, null: false, default: "gt"
      t.float :threshold, null: false, default: 0
      t.integer :window_seconds, null: false, default: 300
      # The condition must hold this long before the monitor alerts.
      t.integer :for_seconds, null: false, default: 0
      # Hold the alert this long after a deploy marker for the app.
      t.integer :deploy_grace_seconds, null: false, default: 0
      t.boolean :notify, null: false, default: true
      # ok | alert | no_data
      t.string :state, null: false, default: "no_data"
      t.datetime :state_since
      t.datetime :pending_since
      t.float :last_value
      t.datetime :last_evaluated_at
      t.text :last_error
      t.timestamps
    end

    create_table :incidents, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :monitor, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.float :peak_value
      t.string :app_slug
      t.datetime :notified_at
      t.timestamps
      t.index %i[household_id opened_at]
      t.index :closed_at, where: "(closed_at IS NULL)"
    end
  end
end
