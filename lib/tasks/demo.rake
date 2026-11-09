# typed: false
# frozen_string_literal: true

# Development data: a pretend fleet reporting a week of telemetry
# (lib/demo). Never loaded by the app itself, refused in production.
namespace :glass do
  desc "Fill this instance with a week of demo telemetry (DAYS=7)"
  task demo: :environment do
    abort "glass:demo is for development and test" if Rails.env.production?

    require Rails.root.join("lib/demo/generator")
    Rake::Task["glass:demo:account"].invoke
    Demo::Generator.new(days: ENV.fetch("DAYS", 7).to_i).run!
  end

  namespace :demo do
    desc "Create the dev household and admin (dev@glass.test / glass-dev-password) if there is none"
    task account: :environment do
      abort "glass:demo is for development and test" if Rails.env.production?
      next if User.exists?

      household = Household.create!(name: "Home")
      User.register!(household: household, email: "dev@glass.test", name: "Dev", password: "glass-dev-password",
        role: User::Role::Admin)
      puts "demo: created dev@glass.test / glass-dev-password"
    end

    desc "Wipe all telemetry (apps and settings in the primary database are kept)"
    task reset: :environment do
      abort "glass:demo is for development and test" if Rails.env.production?

      Telemetry::Partitions.list.each do |partition|
        TelemetryRecord.connection.execute("DROP TABLE IF EXISTS #{TelemetryRecord.connection.quote_table_name(partition.name)}")
      end
      %w[metric_series processes cursors profile_functions profile_stacks].each do |table|
        TelemetryRecord.connection.execute("TRUNCATE #{table} RESTART IDENTITY")
      end
      Telemetry::Partitions.ensure!
      # This process's dictionaries name rows that no longer exist.
      Ingest::SeriesResolver.reset!
      Ingest::ProfileStore.reset!
      puts "demo: telemetry wiped"
    end

    desc "Keep the demo fleet reporting through the real ingest endpoint (GLASS_URL, default http://localhost:3004)"
    task live: :environment do
      abort "glass:demo is for development and test" if Rails.env.production?

      require Rails.root.join("lib/demo/generator")
      require "net/http"
      require "zlib"

      url = URI.join(ENV.fetch("GLASS_URL", "http://localhost:3004"), "/ingest/v1/batch")
      household = Household.instance || abort("run bin/rails glass:demo first")
      Current.household = household
      generator = Demo::Generator.new(output: nil)
      keys = Demo::Fleet::ALL.to_h do |spec|
        app = App.find_by(slug: spec.slug) || abort("run bin/rails glass:demo first")
        [ spec, IngestKey.generate(app: app, name: "demo live").token ]
      end
      at_exit { IngestKey.where(name: "demo live").find_each(&:revoke!) }

      puts "demo: reporting for #{keys.size} apps to #{url} every 10s — ctrl-c to stop"
      last = Time.now.utc - 10
      loop do
        now = Time.now.utc
        keys.each do |spec, key|
          release = generator.releases_for(spec).last[1]
          records = generator.live_records(spec, last, now)
          body = ([ generator.header_for(spec, "web", release) ] + records).map(&:to_json).join("\n")
          request = Net::HTTP::Post.new(url.request_uri, "Authorization" => "Bearer #{key}", "Content-Encoding" => "gzip",
            "Content-Type" => "application/x-ndjson")
          request.body = Zlib.gzip(body)
          # A dev-only loopback post to this very app, mimicking an agent;
          # the shared client is for what Glass itself reaches out to.
          response = Net::HTTP.start(url.host, url.port, open_timeout: 3, read_timeout: 5) { |http| http.request(request) } # rubocop:disable Glass/NoRawNetHttp
          puts "demo: #{spec.slug} #{records.size} records → #{response.code}" unless response.code == "202"
        rescue StandardError => e
          puts "demo: #{spec.slug} failed: #{e.class}: #{e.message}"
        end
        last = now
        sleep 10
      end
    end
  end
end
