# frozen_string_literal: true

module Glass
  class Railtie < ::Rails::Railtie
    # The middleware goes in unconditionally, at the top of the stack: it
    # is a one-line pass-through while the agent is not configured, and the
    # stack can only be changed before the app finishes booting — a
    # Glass.configure in an initializer must still find it there.
    initializer "glass.middleware" do |app|
      app.config.middleware.insert_before(0, Glass::Middleware)
    end

    # Subscribers, patches and the agent thread only when configured, and
    # only once the app is initialized: nothing here has a boot-time cost
    # in an app that is not reporting.
    config.after_initialize do |app|
      if Glass.enabled?
        require_relative "rails"
        Glass::Integration.attach(app)
      end
    end
  end
end
