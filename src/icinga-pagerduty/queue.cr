require "file_utils"

module IcingaPagerduty
  # Raised when a second daemon is started on a spool another one drains.
  class SpoolLockedError < Exception
  end

  # The persistent spool between Icinga and the daemon: one file per event in
  # `queue/`, refused events and their reason in `failed/`.
  #
  # Writers (`enqueue`, run by Icinga) and the reader (the daemon) are distinct
  # processes under distinct users: every write is a temporary file renamed into
  # place, so the daemon never sees a half-written event.
  class Queue
    # Event and reason files carry the PagerDuty key: owner and group only.
    FILE_PERMISSIONS = 0o640

    # Files being written start with this prefix and are never listed.
    TEMP_PREFIX = ".tmp-"

    REASON_SUFFIX = ".reason"

    # flock'ed by the running daemon, at the root of the spool.
    LOCK_FILE = "daemon.lock"

    getter queue_dir : Path
    getter failed_dir : Path
    getter lock_path : Path

    @sequence = 0

    def initialize(root : Path, @clock : -> Time = -> { Time.utc })
      @queue_dir = root / "queue"
      @failed_dir = root / "failed"
      @lock_path = root / LOCK_FILE
      @lock = nil.as(File?)
    end

    def prepare : Nil
      Dir.mkdir_p(@queue_dir)
      Dir.mkdir_p(@failed_dir)
    end

    # Claims the spool for this daemon until `unlock` or the end of the
    # process. The open file is kept in the queue, which lives as long as the
    # daemon: a local the compiler could drop would let the GC finalize the
    # file, and closing it releases the lock.
    def lock : Nil
      file = File.open(@lock_path, "a", perm: FILE_PERMISSIONS)
      begin
        file.flock_exclusive(blocking: false)
      rescue IO::Error
        file.close
        raise SpoolLockedError.new("another daemon already holds #{@lock_path}")
      end
      @lock = file
    end

    def unlock : Nil
      @lock.try &.close
      @lock = nil
    end

    # True while a daemon holds the lock. Probed with a shared lock released at
    # once, so the check never stands in the daemon's way for longer than one
    # system call. A missing lock file means no daemon ever started.
    def daemon_running? : Bool
      file = File.open(@lock_path)
    rescue File::NotFoundError
      false
    else
      begin
        file.flock_shared(blocking: false)
        false
      rescue IO::Error
        true
      ensure
        file.close
      end
    end

    # Names sort in arrival order: nanosecond timestamp first, then a per
    # process sequence for events pushed within the same clock reading, then
    # the pid, which keeps two concurrent writers from colliding.
    #
    # The timestamp never goes below the newest one queued: a wall clock
    # stepped back between a trigger and its resolve would otherwise sort the
    # resolve first, and the incident would stay open.
    def push(body : String) : Path
      @sequence += 1
      stamp = {@clock.call.to_unix_ns, newest_stamp + 1}.max
      name = "#{stamp.to_s.rjust(20, '0')}-#{@sequence.to_s.rjust(6, '0')}-#{Process.pid}.json"
      write_atomically(@queue_dir / name, body)
    end

    def entries : Array(Path)
      Dir.children(@queue_dir)
        .reject(&.starts_with?('.'))
        .select(&.ends_with?(".json"))
        .sort!
        .map { |name| @queue_dir / name }
    end

    def delete(path : Path) : Nil
      File.delete(path)
    end

    # The reason is written first: an event in `failed/` always has it.
    #
    # The rename keeps the event's mtime, which is when it was queued; it is
    # reset to now so that the retention counts from the refusal, like the
    # reason beside it.
    def fail(path : Path, reason : String) : Nil
      now = @clock.call
      reason_path = write_atomically(@failed_dir / "#{path.basename}#{REASON_SUFFIX}", "#{reason}\n")
      File.touch(reason_path, now)
      failed = @failed_dir / path.basename
      File.rename(path, failed)
      File.touch(failed, now)
    end

    def refused_count : Int32
      Dir.children(@failed_dir).count { |name| !name.starts_with?('.') && name.ends_with?(".json") }
    end

    # Returns the number of failed events deleted.
    def purge_failed(older_than : Time::Span) : Int32
      limit = @clock.call - older_than
      purged = 0

      Dir.children(@failed_dir).each do |name|
        path = @failed_dir / name
        next unless File.info(path).modification_time < limit

        File.delete(path)
        purged += 1 if name.ends_with?(".json")
      end

      purged
    end

    # 0 when the queue is empty.
    private def newest_stamp : Int128
      entries.last?.try(&.basename.split('-', 2)[0].to_i128?) || Int128.new(0)
    end

    # Synced before and after the rename: without it, a host crash right after
    # an enqueue can leave the name on disk with no content behind it, and an
    # empty event is refused by PagerDuty instead of paging.
    private def write_atomically(path : Path, content : String) : Path
      temp = path.parent / "#{TEMP_PREFIX}#{path.basename}"
      File.open(temp, "w", perm: FILE_PERMISSIONS) do |file|
        file.print(content)
        file.fsync
      end
      # File.open applies `perm` through the umask: set it explicitly.
      File.chmod(temp, FILE_PERMISSIONS)
      File.rename(temp, path)
      File.open(path.parent, &.fsync)
      path
    end
  end
end
