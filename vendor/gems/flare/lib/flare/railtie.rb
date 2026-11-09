# frozen_string_literal: true

module Flare
  class Railtie < Rails::Railtie
    # Subscribe as early as possible so initializer-time errors report too.
    # Without a DSN nothing is registered and the app runs exactly as before.
    initializer "flare.error_subscriber" do
      Rails.error.subscribe(Flare::Subscriber.new) if Flare.enabled?
    end

    config.after_initialize do
      if Flare.enabled?
        Flare.config.logger ||= Rails.logger
        # Honor the app's own PII rules on top of the built-in patterns.
        Flare.config.rails_filters = Rails.application.config.filter_parameters || []
      end
    end
  end
end
