# typed: strict
# frozen_string_literal: true

# Thin, careful wrapper around the external tools fog-backup/2 runs (pg_dump,
# pg_restore, tar — FogBackup::Tool).
#
# Everything here is about not trusting the subprocess: explicit argv (never
# a shell string), a hard timeout, bounded output capture, and the child
# killed by process group so a spawned grandchild dies with its parent.
module ToolRunner
  extend T::Sig

  class Error < StandardError; end
  class Timeout < Error; end

  DEFAULT_TIMEOUT = T.let(900, Integer)
  MAX_OUTPUT_BYTES = T.let(256 * 1024, Integer)

  class Result < T::Struct
    extend T::Sig

    const :status, Integer
    const :stdout, String
    const :stderr, String

    sig { returns(T::Boolean) }
    def success? = status.zero?
  end

  sig { params(argv: T::Array[String], timeout: Integer, env: T::Hash[String, String]).returns(Result) }
  def self.run(argv, timeout: DEFAULT_TIMEOUT, env: {})
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe

    # pgroup: true so the whole tree can be signalled. env entries overlay the
    # parent environment (how pg_dump gets PGPASSWORD without it appearing in
    # argv).
    pid = T.unsafe(Process).spawn(env, *argv, out: out_w, err: err_w, pgroup: true)
    out_w.close
    err_w.close

    readers = [ reader_thread(out_r), reader_thread(err_r) ]
    waiter = Thread.new { Process.waitpid2(pid) }

    if waiter.join(timeout).nil?
      kill_group(pid)
      readers.each { |thread| thread.join(5) }
      if waiter.join(5).nil?
        # A child wedged in uninterruptible IO (a hung NAS mount) can outlive
        # even SIGKILL's delivery window. Hand the reaping to a detached
        # watcher rather than leaking the waiter thread and a zombie.
        waiter.kill
        Process.detach(pid)
      end
      raise Timeout, "#{argv.first} exceeded #{timeout}s"
    end

    status = T.cast(waiter.value, [ Integer, Process::Status ])[1]
    stdout = readers.fetch(0).value.to_s
    stderr = readers.fetch(1).value.to_s

    Result.new(status: status.exitstatus || -1, stdout: stdout, stderr: stderr)
  ensure
    [ out_r, err_r ].each { |io| io.close unless io.nil? || io.closed? }
  end

  # Reads until EOF but stops accumulating past the cap — a tool that goes
  # berserk on stderr shouldn't be able to exhaust memory.
  sig { params(io: IO).returns(Thread) }
  def self.reader_thread(io)
    Thread.new do
      buffer = +""
      begin
        while (chunk = io.read(65_536))
          buffer << chunk if buffer.bytesize < MAX_OUTPUT_BYTES
        end
      rescue IOError
        nil
      end
      buffer
    end
  end
  private_class_method :reader_thread

  sig { params(pid: Integer).void }
  def self.kill_group(pid)
    group = Process.getpgid(pid)
    Process.kill("-TERM", group)
    # Poll through the grace period instead of a flat sleep(2): most tools
    # die instantly, and this blocks a worker thread. getpgid raises ESRCH
    # once the group is gone, short-circuiting into the rescue.
    20.times do
      sleep 0.1
      Process.getpgid(pid)
    end
    Process.kill("-KILL", group)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
  private_class_method :kill_group

  # Positive probes memoized for the process lifetime: a tool that answered
  # once is installed. Missing tools keep probing — the failed spawn is
  # cheap, and it lets a newly-installed binary be noticed without a restart.
  @versions = T.let({}, T::Hash[String, String])

  VERSION_FLAGS = T.let(%w[--version -version].freeze, T::Array[String])

  sig { params(tool: String).returns(T.nilable(String)) }
  def self.version(tool)
    memoized = @versions[tool]
    return memoized if memoized

    VERSION_FLAGS.each do |flag|
      result = run([ tool, flag ], timeout: 20)
      next unless result.success?

      line = result.stdout.strip.lines.first&.strip
      return @versions[tool] = line if line.present?
    end
    nil
  rescue StandardError
    nil
  end
end
