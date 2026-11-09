# typed: strict
# frozen_string_literal: true

# A credential that remembers when it was last used (`last_used_at`), for
# the screens that list them. Checked on every request, so stamped at most
# once per USE_STAMP_INTERVAL.
module UseStamped
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  USE_STAMP_INTERVAL = T.let(1.hour, ActiveSupport::Duration)

  sig { void }
  def record_use!
    stamp_throttled!(:last_used_at, every: USE_STAMP_INTERVAL)
  end
end
