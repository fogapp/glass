# frozen_string_literal: true

# Widgets were a flow — a width of a three-column grid and a chart height —
# and now each has a place on a twelve-column grid. Every dashboard's
# widgets take the places their flow gave them (Dashboard.arrange).
class PlaceDashboardWidgets < ActiveRecord::Migration[8.1]
  class Board < ActiveRecord::Base
    self.table_name = "dashboards"
  end

  def up
    Board.find_each do |board|
      next unless board.widgets.is_a?(Array) && board.widgets.all?(Hash)

      board.update_columns(widgets: Dashboard.arrange(board.widgets))
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
