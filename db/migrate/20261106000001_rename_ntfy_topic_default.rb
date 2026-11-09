# frozen_string_literal: true

# The product is Glass now: a household that never chose a topic gets
# "glass". A topic someone already set is theirs and is left as it is —
# their phones are subscribed to it.
class RenameNtfyTopicDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :app_settings, :ntfy_topic, "glass"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
