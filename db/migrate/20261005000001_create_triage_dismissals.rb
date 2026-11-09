# frozen_string_literal: true

# A person's answer to a triage finding: dismissed (hidden until it gets
# worse than it was) or ignored (hidden for good). Keyed by the finding's
# id, which is its subject — so the answer outlives any one range.
class CreateTriageDismissals < ActiveRecord::Migration[8.1]
  def change
    create_table :triage_dismissals, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.text :finding_id, null: false
      # dismissed | ignored
      t.string :mode, null: false
      # What the finding was when it was dismissed: what "worse" is measured against.
      t.float :score, null: false
      t.string :severity, null: false
      t.string :title, null: false
      t.timestamps
      t.index %i[household_id finding_id], unique: true
    end
  end
end
