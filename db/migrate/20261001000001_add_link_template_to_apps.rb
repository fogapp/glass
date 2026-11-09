# frozen_string_literal: true

# Where an app keeps what Glass does not. An agent
# harness reports numbers and names and never what was said; the content of
# a run lives in the harness's own console. A link template turns a row here
# into a link there: `https://assistant.example.net/traces/{run}`.
class AddLinkTemplateToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :link_template, :string
  end
end
