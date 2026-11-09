# typed: strict
# frozen_string_literal: true

require "zlib"

module Ingest
  # The request body as text: read with a ceiling, inflated with a ceiling.
  # Both limits are enforced while reading, never after — a gzip bomb must
  # not get to be 32 GiB in memory before anyone asks how big it is.
  module Body
    extend T::Sig

    MAX_WIRE_BYTES = T.let(4.megabytes, Integer)
    MAX_INFLATED_BYTES = T.let(32.megabytes, Integer)
    CHUNK = T.let(64.kilobytes, Integer)

    class TooLarge < StandardError; end
    class Unreadable < StandardError; end

    sig { params(request: ActionDispatch::Request).returns(String) }
    def self.read(request)
      raw = request.body.read(MAX_WIRE_BYTES + 1).to_s
      raise TooLarge, "Body exceeds #{MAX_WIRE_BYTES / 1.megabyte} MiB" if raw.bytesize > MAX_WIRE_BYTES

      text = gzip?(request, raw) ? inflate(raw) : raw
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub("�")
    end

    # By header, or by magic bytes when a proxy dropped the header.
    sig { params(request: ActionDispatch::Request, raw: String).returns(T::Boolean) }
    def self.gzip?(request, raw)
      request.headers["Content-Encoding"].to_s.downcase.include?("gzip") || raw.byteslice(0, 2) == "\x1f\x8b".b
    end
    private_class_method :gzip?

    sig { params(raw: String).returns(String) }
    def self.inflate(raw)
      out = +"".b
      reader = Zlib::GzipReader.new(StringIO.new(raw))
      while (chunk = reader.read(CHUNK))
        out << chunk
        raise TooLarge, "Body inflates past #{MAX_INFLATED_BYTES / 1.megabyte} MiB" if out.bytesize > MAX_INFLATED_BYTES
      end
      out
    rescue Zlib::Error => e
      raise Unreadable, "Body is not valid gzip: #{e.message}"
    ensure
      reader&.close
    end
    private_class_method :inflate
  end
end
