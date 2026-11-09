# frozen_string_literal: true

# The fog apps a person removed from Glass: fog still runs them, so without
# this the next sync would make them again.
class AddFogIgnoredAppsToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :fog_ignored_apps, :jsonb, null: false, default: []
  end
end
