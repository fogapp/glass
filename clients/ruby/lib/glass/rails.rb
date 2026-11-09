# frozen_string_literal: true

require_relative "net_http"
require_relative "logs"

module Glass
  # Everything that needs Rails: the notification subscribers, the Active
  # Job trace propagation, the error subscriber, the log sink, the executor
  # hook. Installed once, by the railtie after initialization (or by the
  # late-attach path when the railtie could not load), and only when the
  # agent is configured — an inert app is not subscribed to anything.
  #
  # Every subscriber body rescues StandardError: Rails 7.1+ re-raises a
  # subscriber's exception into the instrumented code, so a bug here would
  # otherwise become the app's 500.
  module Integration
    class << self
      def attach(app)
        return if @attached
        @attached = true
        config = Glass.config
        config.logger ||= ::Rails.logger if ::Rails.respond_to?(:logger)
        config.rails_filters = app.config.filter_parameters || [] if app.respond_to?(:config)
        config.app_root = ::Rails.root.to_s if ::Rails.respond_to?(:root) && ::Rails.root
        install_subscribers(config)
        JobPropagation.install! if config.feature?(:jobs) && defined?(::ActiveJob::Base)
        NetHttp.install! if config.feature?(:http)
        ::Rails.error.subscribe(ErrorSubscriber.new) if config.feature?(:errors) && ::Rails.respond_to?(:error)
        Logs.attach(config)
        if app.respond_to?(:executor)
          app.executor.to_run { Glass::Tracer.set_error_context }
        end
        Glass.start if autostart?(config)
      end

      # Reset for tests.
      def detach!
        @attached = false
      end

      private

      def install_subscribers(config)
        n = ::ActiveSupport::Notifications
        if config.feature?(:requests)
          n.subscribe("start_processing.action_controller", ControllerSubscriber.new)
          n.subscribe("process_action.action_controller", ControllerSubscriber.new)
        end
        if config.feature?(:sql)
          n.monotonic_subscribe("sql.active_record", &SQL_HANDLER)
        end
        if config.feature?(:views)
          view = ViewSubscriber.new
          %w[render_template.action_view render_partial.action_view render_collection.action_view].each do |name|
            n.subscribe(name, view)
          end
        end
        if config.feature?(:cache)
          cache = CacheSubscriber.new
          n.subscribe("cache_read.active_support", cache)
          n.subscribe("cache_read_multi.active_support", cache)
        end
        if config.feature?(:jobs)
          n.subscribe("perform.active_job", JobSubscriber.new)
          enqueue = EnqueueSubscriber.new
          n.subscribe("enqueue.active_job", enqueue)
          n.subscribe("enqueue_at.active_job", enqueue)
        end
      end

      # Servers and job runners start the agent at boot so idle processes
      # heartbeat; consoles, runners and rake tasks start it on their first
      # record and stay quiet otherwise.
      def autostart?(config)
        return config.autostart unless config.autostart.nil?
        return true if defined?(::Rails::Server)
        return true if defined?(::Puma) && ::Puma.instance_variable_get(:@get_stats)
        config.process_kind == "worker"
      rescue StandardError
        false
      end
    end

    # start_processing names the transaction as soon as the route is known
    # (so an in-flight request is attributable in a profile window);
    # process_action fills in the rest and resolves the user while Current
    # is still set. Without the middleware (late attach), the controller
    # action itself becomes the transaction.
    class ControllerSubscriber
      def start(name, _id, payload)
        return unless Glass.enabled?
        txn = Tracer.current
        if txn.nil? && name == "process_action.action_controller" && !defined?(Glass::Railtie)
          txn = Transaction.new("request")
          txn.controller_owned = true
          txn.method = payload[:method]
          txn.path = payload[:path].to_s.split("?", 2).first
          Thread.current[Tracer::KEY] = txn
        end
        return unless txn
        txn.name ||= "#{payload[:controller]}##{payload[:action]}"
      rescue StandardError => e
        Glass.error("controller", e)
      end

      def finish(name, _id, payload)
        return unless name == "process_action.action_controller" && Glass.enabled?
        txn = Tracer.current or return
        txn.name = "#{payload[:controller]}##{payload[:action]}"
        request = payload[:request]
        if request.respond_to?(:route_uri_pattern) && (pattern = request.route_uri_pattern)
          txn.route = pattern.sub("(.:format)", "")
        end
        fmt = payload[:format]
        txn.format = fmt.to_s[0, 40] if fmt && fmt != "*/*"
        txn.http ||= payload[:status] if payload[:status]
        if (exception = payload[:exception_object])
          txn.mark_error(exception.class.name)
        elsif payload[:exception].is_a?(Array)
          txn.mark_error(payload[:exception].first)
        end
        identity = Tracer.resolve_identity
        if identity
          txn.user = identity.first
          txn.user_identity = identity
          Tracer.join_visit(txn) if txn.visit
        end
        if txn.controller_owned
          txn.http = payload[:status] || (txn.status == "error" ? 500 : nil)
          txn.finish
          Thread.current[Tracer::KEY] = nil
          Tracer.complete(txn)
        end
      rescue StandardError => e
        Glass.error("controller", e)
      end
    end

    SQL_HANDLER = lambda do |_name, start, finish, _id, payload|
      txn = Tracer.current
      next unless txn && Glass.enabled?
      name = payload[:name]
      next if name == "SCHEMA" || name == "TRANSACTION"
      normalized = Sql.normalize(payload[:sql])
      name = Sql.label(normalized) if name.nil? || name.empty? || name == "SQL"
      txn.sql(name, normalized, start, (finish - start) * 1000.0, payload[:cached] == true)
    rescue StandardError => e
      Glass.error("sql", e)
    end

    class ViewSubscriber
      def start(_name, _id, payload)
        txn = Tracer.current or return
        return unless Glass.enabled?
        identifier = relative(payload[:identifier])
        payload[:glass_span] = txn.view_start(identifier, identifier)
      rescue StandardError => e
        Glass.error("view", e)
      end

      def finish(name, _id, payload)
        txn = Tracer.current or return
        return unless Glass.enabled?
        span = payload.delete(:glass_span)
        attrs = { "count" => payload[:count] } if name.start_with?("render_collection") && payload[:count]
        txn.view_finish(span, nil, attrs)
      rescue StandardError => e
        Glass.error("view", e)
      end

      private

      def relative(identifier)
        id = identifier.to_s
        root = Glass.config.app_root
        id = id.delete_prefix(root + "/") if root && !root.empty?
        id[0, 200]
      end
    end

    class CacheSubscriber
      def start(*); end

      def finish(name, _id, payload)
        txn = Tracer.current or return
        return unless Glass.enabled?
        if name == "cache_read_multi.active_support"
          keys = payload[:key].is_a?(Array) ? payload[:key].size : 0
          hits = payload[:hits].is_a?(Array) ? payload[:hits].size : 0
          txn.cache_hit += hits
          txn.cache_miss += [keys - hits, 0].max
        elsif payload[:hit]
          txn.cache_hit += 1
        else
          txn.cache_miss += 1
        end
      rescue StandardError => e
        Glass.error("cache", e)
      end
    end

    # perform.active_job: a `job` transaction — unless a transaction is
    # already running on this fiber (perform_now inside a request), in
    # which case the job is a `custom` span of it.
    class JobSubscriber
      def start(_name, _id, payload)
        return unless Glass.enabled?
        job = payload[:job]
        if (txn = Tracer.current)
          txn.start_span("custom", job.class.name, nil, nil, job)
        else
          Tracer.start_job(job)
        end
      rescue StandardError => e
        Glass.error("job", e)
      end

      def finish(_name, _id, payload)
        return unless Glass.enabled?
        txn = Tracer.current or return
        job = payload[:job]
        error = payload[:exception_object]
        if txn.kind == "job" && txn.owner.equal?(job)
          Tracer.finish_job(txn, job, error)
        elsif (span = txn.stack.reverse_each.find { |s| s.ref.equal?(job) })
          txn.finish_span(span, nil, error: error)
        end
      rescue StandardError => e
        Glass.error("job", e)
      end
    end

    # The enqueue span is open while the adapter serializes the job, which
    # is how JobPropagation finds it as the job's parent.
    class EnqueueSubscriber
      def start(_name, _id, payload)
        txn = Tracer.current or return
        return unless Glass.enabled?
        job = payload[:job]
        span = txn.start_span("enqueue", job.class.name, job.queue_name.to_s, nil, job)
        span.attrs = { "queue" => job.queue_name.to_s } if span
      rescue StandardError => e
        Glass.error("enqueue", e)
      end

      def finish(_name, _id, payload)
        txn = Tracer.current or return
        return unless Glass.enabled?
        job = payload[:job]
        span = txn.stack.reverse_each.find { |s| s.ref.equal?(job) }
        txn.finish_span(span, nil, error: payload[:exception_object]) if span
      rescue StandardError => e
        Glass.error("enqueue", e)
      end
    end

    # Carries the trace across the queue: serialize adds the current
    # traceparent (the open enqueue span) to the job data, deserialize
    # reads it back for Tracer.start_job. Unknown keys in job data are
    # ignored by every adapter, so no app change is needed.
    module JobPropagation
      KEY = "glass_traceparent"

      def self.install!
        return if @installed
        @installed = true
        ::ActiveJob::Base.prepend(Methods)
      end

      module Methods
        attr_reader :glass_traceparent

        def serialize
          data = super
          begin
            parent = Glass.traceparent || @glass_traceparent
            data[KEY] = parent if parent
          rescue StandardError => e
            Glass.error("job_serialize", e)
          end
          data
        end

        def deserialize(job_data)
          super
          @glass_traceparent = job_data[KEY] if job_data.is_a?(Hash) && job_data[KEY].is_a?(String)
        rescue StandardError => e
          Glass.error("job_deserialize", e)
        end
      end
    end

    # Errors are counted, and an unhandled one marks the transaction it
    # happened in. Grouping and triage stay Flare's.
    class ErrorSubscriber
      def report(error, handled:, severity:, context:, source: nil)
        return unless Glass.enabled?
        Glass.increment("rails.errors", tags: { error: error.class.name, handled: handled ? "true" : "false" })
        return if handled
        Tracer.current&.mark_error(error.class.name)
      rescue StandardError => e
        Glass.error("errors", e)
      end
    end
  end
end
