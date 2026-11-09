# typed: strict
# frozen_string_literal: true

require "sys/filesystem"

# Facts about the box this process runs on, for Settings → About — the same
# "This server" fact grid fog's System overview shows (fog's internal/server/
# handlers.go handleSystem), read from where Ruby can see them. Every fact
# degrades to nil rather than raising: the page is for finding out what a
# deployment is, and a host that won't say its memory size shouldn't hide
# its hostname.
module MachineInfo
  extend T::Sig

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def self.report
    uname = Etc.uname
    {
      hostname: Socket.gethostname,
      os: os_name(uname),
      kernel: "#{uname[:sysname]} #{uname[:release]}",
      arch: uname[:machine],
      cpus: Etc.nprocessors,
      memory_total_bytes: memory_total_bytes,
      containerized: File.exist?("/.dockerenv"),
      pid: Process.pid,
      user: process_user
    }
  end

  # The size of, and the space left on, the filesystem holding `path` — nil
  # for both when it cannot be read (an exotic mount, a missing directory).
  sig { params(path: String).returns({ total_bytes: T.nilable(Integer), free_bytes: T.nilable(Integer) }) }
  def self.disk_stats(path)
    stat = Sys::Filesystem.stat(path)
    { total_bytes: stat.bytes_total, free_bytes: stat.bytes_available }
  rescue StandardError
    { total_bytes: nil, free_bytes: nil }
  end

  # "Debian GNU/Linux 12 (bookworm)" inside the image; the kernel name and
  # release on a host without /etc/os-release (a Mac in development).
  sig { params(uname: T::Hash[Symbol, String]).returns(String) }
  def self.os_name(uname)
    release = Pathname.new("/etc/os-release")
    if release.readable?
      pretty = release.each_line.find { |line| line.start_with?("PRETTY_NAME=") }
      name = pretty&.delete_prefix("PRETTY_NAME=")&.strip&.delete('"')
      return name if name.present?
    end
    "#{uname[:sysname]} #{uname[:release]}"
  rescue SystemCallError
    "#{uname[:sysname]} #{uname[:release]}"
  end
  private_class_method :os_name

  # /proc/meminfo is the container's view (cgroup limits aside); sysctl is
  # the development-Mac fallback. Anything else reports "unknown".
  sig { returns(T.nilable(Integer)) }
  def self.memory_total_bytes
    meminfo = Pathname.new("/proc/meminfo")
    if meminfo.readable?
      line = meminfo.each_line.find { |entry| entry.start_with?("MemTotal:") }
      kib = line&.split&.fetch(1, nil)&.to_i
      return kib * 1024 if kib&.positive?
    end
    return nil unless RUBY_PLATFORM.include?("darwin")

    bytes = `sysctl -n hw.memsize 2>/dev/null`.strip.to_i
    bytes.positive? ? bytes : nil
  rescue SystemCallError
    nil
  end
  private_class_method :memory_total_bytes

  sig { returns(T.nilable(String)) }
  def self.process_user
    Etc.getpwuid(Process.uid)&.name
  rescue ArgumentError
    # A uid with no passwd entry — fog runs the image as uid 1000, which the
    # Dockerfile names, but a bind-mounted /etc/passwd might not.
    nil
  end
  private_class_method :process_user
end
