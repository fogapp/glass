# typed: strict
# frozen_string_literal: true

require "rubygems/package"

module FogBackup
  # The gate in front of a restore (fog's docs/backup-contract.md): refuse
  # wrong-app, newer-schema, corrupt, or wrong-keys artifacts before touching
  # data; make identity drift (a different GLASS_HOST) an explicit, confirmed
  # decision rather than a silent pass. Runs at staging time and again at
  # restore time — the artifact may have sat armed across a redeploy.
  module Preflight
    extend T::Sig

    class Result < T::Struct
      extend T::Sig

      const :errors, T::Array[String]
      const :warnings, T::Array[String]
      const :manifest, T.nilable(Manifest::Parsed)

      sig { returns(T::Boolean) }
      def ok? = errors.empty?
    end

    sig { params(artifact_path: Pathname, confirm_identity: T::Boolean).returns(Result) }
    def self.check(artifact_path:, confirm_identity: false)
      errors = T.let([], T::Array[String])
      warnings = T.let([], T::Array[String])

      unless artifact_path.exist?
        return Result.new(errors: [ "No artifact staged at #{artifact_path}" ], warnings: [], manifest: nil)
      end

      digests = T.let({}, T::Hash[String, T::Hash[Symbol, T.untyped]])
      manifest_json = T.let(nil, T.nilable(String))
      begin
        manifest_json, digests = scan_artifact(artifact_path)
      rescue StandardError => e
        return Result.new(errors: [ "Artifact is not readable as a tar: #{e.message}" ], warnings: [], manifest: nil)
      end
      if manifest_json.nil?
        return Result.new(errors: [ "Artifact has no manifest.json" ], warnings: [], manifest: nil)
      end

      manifest = begin
        Manifest.parse(manifest_json)
      rescue JSON::ParserError => e
        return Result.new(errors: [ "Manifest is not valid JSON: #{e.message}" ], warnings: [], manifest: nil)
      end

      unless Manifest::ACCEPTED_FORMATS.include?(manifest.format)
        errors << "Artifact declares format #{manifest.format.inspect}, expected one of #{Manifest::ACCEPTED_FORMATS.join(", ")}"
      end
      errors << "Artifact is for app #{manifest.app.inspect}, this is #{Manifest::APP}" if manifest.app != Manifest::APP

      check_schema_version(manifest, errors)
      check_components(manifest, digests, errors)
      check_extensions(manifest, errors)
      check_secrets(manifest, errors)
      check_identity(manifest, confirm_identity, errors, warnings)

      Result.new(errors: errors, warnings: warnings, manifest: manifest)
    end

    # One pass over the tar: pull the manifest and hash every other entry, so
    # checksum verification never needs the artifact extracted.
    sig { params(artifact_path: Pathname).returns([ T.nilable(String), T::Hash[String, T::Hash[Symbol, T.untyped]] ]) }
    def self.scan_artifact(artifact_path)
      manifest_json = T.let(nil, T.nilable(String))
      digests = T.let({}, T::Hash[String, T::Hash[Symbol, T.untyped]])
      artifact_path.open("rb") do |io|
        T.unsafe(Gem::Package::TarReader).new(io) do |tar|
          tar.each do |entry|
            name = entry.full_name.delete_prefix("./")
            if name == "manifest.json"
              manifest_json = entry.read.to_s
              next
            end
            digest = Digest::SHA256.new
            bytes = T.let(0, Integer)
            while (chunk = entry.read(1 << 16))
              digest << chunk
              bytes += chunk.bytesize
            end
            digests[name] = { sha256: digest.hexdigest, bytes: bytes }
          end
        end
      end
      [ manifest_json, digests ]
    end

    sig { params(manifest: Manifest::Parsed, errors: T::Array[String]).void }
    def self.check_schema_version(manifest, errors)
      code = Manifest.code_schema_version
      return if manifest.schema_version <= code

      errors << "Artifact schema #{manifest.schema_version} is newer than this code's #{code} — " \
        "update the app first, then restore (never restore forward)"
    end
    private_class_method :check_schema_version

    sig { params(manifest: Manifest::Parsed, digests: T::Hash[String, T::Hash[Symbol, T.untyped]], errors: T::Array[String]).void }
    def self.check_components(manifest, digests, errors)
      manifest.components.each do |component|
        path = component["path"].to_s
        actual = digests[path]
        if actual.nil?
          errors << "Component #{path} is listed in the manifest but missing from the artifact"
          next
        end
        if actual[:sha256] != component["sha256"].to_s
          errors << "Component #{path} fails checksum verification — the artifact is corrupt"
        elsif actual[:bytes] != component["bytes"].to_i
          errors << "Component #{path} is #{actual[:bytes]} bytes, manifest says #{component["bytes"]}"
        end
      end
    end
    private_class_method :check_components

    sig { params(manifest: Manifest::Parsed, errors: T::Array[String]).void }
    def self.check_extensions(manifest, errors)
      installed = Manifest.installed_extensions
      manifest.extensions.each do |name, wanted|
        current = installed[name]
        if current.nil?
          errors << "Postgres extension #{name} (#{wanted}) is required by the artifact but not installed"
          next
        end
        begin
          if Gem::Version.new(current) < Gem::Version.new(wanted)
            errors << "Postgres extension #{name} is #{current}, artifact needs #{wanted} or newer"
          end
        rescue ArgumentError
          nil # unparseable extension version strings — presence is enough
        end
      end
    end
    private_class_method :check_extensions

    sig { params(manifest: Manifest::Parsed, errors: T::Array[String]).void }
    def self.check_secrets(manifest, errors)
      current = Manifest.secrets_fingerprint
      manifest.secrets_fingerprint.each do |key, fingerprint|
        if current[key].nil?
          errors << "#{key} is not set on this instance but the artifact's data was written with it — " \
            "restoring would produce unreadable ciphertext"
        elsif current[key] != fingerprint
          errors << "#{key} differs from the one the artifact was written with — " \
            "restoring would produce unreadable ciphertext; inject the original value first"
        end
      end
    end
    private_class_method :check_secrets

    # GLASS_HOST is the WebAuthn relying-party id every passkey is bound to, and
    # the URL peers stored when fog introduced us. A host change invalidates
    # every passkey and strands every peer's connection — a migration, not a
    # settings change, so proceeding must be a decision, never a default.
    sig do
      params(manifest: Manifest::Parsed, confirm_identity: T::Boolean,
        errors: T::Array[String], warnings: T::Array[String]).void
    end
    def self.check_identity(manifest, confirm_identity, errors, warnings)
      artifact_host = manifest.identity_host
      current_host = GlassHost.host
      return if artifact_host.nil? || artifact_host == current_host

      message = "Artifact was produced for host #{artifact_host.inspect}, this instance is #{current_host.inspect} — " \
        "a host change breaks every passkey and strands every peer's stored connection"
      if confirm_identity
        warnings << "#{message} (confirmed, proceeding)"
      else
        errors << "#{message}; pass confirm_identity to proceed anyway"
      end
    end
    private_class_method :check_identity
  end
end
