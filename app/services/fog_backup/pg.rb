# typed: strict
# frozen_string_literal: true

module FogBackup
  # The primary database as pg_dump and pg_restore are pointed at it: the
  # app's own connection, with the password in the environment rather than
  # in argv where `ps` would show it.
  module Pg
    extend T::Sig

    sig { returns(T::Array[String]) }
    def self.connection_args
      config = self.config
      [
        "-h", config[:host].to_s,
        "-p", (config[:port] || 5432).to_s,
        "-U", config[:username].to_s,
        "-d", config[:database].to_s
      ]
    end

    # A connection of its own, outside Active Record's pool: a session-level
    # advisory lock taken on it survives the pool reconnecting under a
    # restore (Restorer).
    sig { returns(PG::Connection) }
    def self.connect
      config = self.config
      PG.connect(host: config[:host], port: config[:port] || 5432, user: config[:username],
        password: config[:password], dbname: config[:database])
    end

    sig { returns(T::Hash[String, String]) }
    def self.env = { "PGPASSWORD" => config[:password].to_s }

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.config = ActiveRecord::Base.connection_db_config.configuration_hash
    private_class_method :config
  end
end
