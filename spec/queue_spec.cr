require "./spec_helper"
require "file_utils"

Spectator.describe IcingaPagerduty::Queue do
  let(root) do
    path = Path[Dir.tempdir, "icinga-pagerduty-spec-#{Random::Secure.hex(6)}"]
    Dir.mkdir(path)
    path
  end

  # A clock the spec moves by hand, so that ordering never depends on how fast
  # the machine running the suite happens to be.
  let(clock) { [Time.utc(2026, 10, 5, 4, 0, 0)] }
  let(queue) { IcingaPagerduty::Queue.new(root, clock: -> { clock[0] }) }

  after_each { FileUtils.rm_rf(root) }

  def names_in(dir : Path) : Array(String)
    Dir.children(dir).sort
  end

  describe "#prepare" do
    it "creates the queue and failed directories" do
      queue.prepare

      expect(Dir.exists?(root / "queue")).to be_true
      expect(Dir.exists?(root / "failed")).to be_true
    end
  end

  describe "#push" do
    before_each { queue.prepare }

    it "stores the body in a file of the queue directory" do
      path = queue.push(%({"event_type":"trigger"}))

      expect(path.parent).to eq(root / "queue")
      expect(File.read(path)).to eq(%({"event_type":"trigger"}))
    end

    # The event carries the PagerDuty key: readable by the daemon's group, by
    # nobody else.
    it "makes the file readable by owner and group only" do
      path = queue.push("{}")

      expect(File.info(path).permissions.value).to eq(0o640)
    end

    it "leaves no temporary file behind" do
      queue.push("{}")

      expect(names_in(root / "queue").size).to eq(1)
    end

    it "fails when the queue directory is missing" do
      FileUtils.rm_rf(root / "queue")

      expect { queue.push("{}") }.to raise_error(File::NotFoundError)
    end
  end

  describe "#entries" do
    before_each { queue.prepare }

    it "lists events in arrival order" do
      first = queue.push("1")
      clock[0] += 1.second
      second = queue.push("2")
      clock[0] += 1.millisecond
      third = queue.push("3")

      expect(queue.entries).to eq([first, second, third])
    end

    # Within the same clock tick the order must still be the push order: a
    # trigger and its resolve can be queued within the same nanosecond reading.
    it "keeps the push order within the same instant" do
      paths = (1..20).map { |i| queue.push(i.to_s) }

      expect(queue.entries).to eq(paths)
    end

    # A wall clock stepped back (NTP, VM resume) between a trigger and its
    # resolve must not sort the resolve first.
    it "keeps the push order when the clock goes back" do
      first = queue.push("trigger")
      clock[0] -= 1.second
      second = IcingaPagerduty::Queue.new(root, clock: -> { clock[0] }).push("resolve")

      expect(queue.entries).to eq([first, second])
    end

    it "ignores files being written" do
      File.write(root / "queue" / ".tmp-half-written", "{")

      expect(queue.entries).to be_empty
    end

    it "is empty when nothing is queued" do
      expect(queue.entries).to be_empty
    end
  end

  describe "#delete" do
    before_each { queue.prepare }

    it "removes the event from the queue" do
      path = queue.push("{}")
      queue.delete(path)

      expect(queue.entries).to be_empty
    end
  end

  describe "#fail" do
    before_each { queue.prepare }

    it "moves the event to the failed directory with the reason beside it" do
      path = queue.push(%({"event_type":"trigger"}))
      queue.fail(path, "HTTP 400: invalid service key")

      expect(queue.entries).to be_empty
      name = path.basename
      expect(names_in(root / "failed")).to eq([name, "#{name}.reason"])
      expect(File.read(root / "failed" / name)).to eq(%({"event_type":"trigger"}))
      expect(File.read(root / "failed" / "#{name}.reason")).to eq("HTTP 400: invalid service key\n")
    end

    # The retention counts from the refusal: an event that waited out a long
    # PagerDuty outage before being refused must not be purged at once.
    it "dates the refused event and its reason from the refusal" do
      path = queue.push("{}")
      File.touch(path, clock[0] - 30.days)
      queue.fail(path, "HTTP 400")

      expect(File.info(root / "failed" / path.basename).modification_time).to eq(clock[0])
      expect(File.info(root / "failed" / "#{path.basename}.reason").modification_time).to eq(clock[0])
      expect(queue.purge_failed(7.days)).to eq(0)
    end
  end

  describe "#refused_count" do
    before_each { queue.prepare }

    it "counts the refused events, not their reasons" do
      queue.fail(queue.push("1"), "HTTP 400")
      queue.fail(queue.push("2"), "HTTP 422")

      expect(queue.refused_count).to eq(2)
    end
  end

  describe "#daemon_running?" do
    before_each { queue.prepare }
    after_each { queue.unlock }

    it "is false before any daemon started" do
      expect(queue.daemon_running?).to be_false
    end

    it "is true while a daemon holds the spool" do
      queue.lock

      expect(IcingaPagerduty::Queue.new(root).daemon_running?).to be_true
    end

    it "is false once the daemon released it" do
      queue.lock
      queue.unlock

      expect(IcingaPagerduty::Queue.new(root).daemon_running?).to be_false
    end

    it "never stands in the way of a daemon starting" do
      # The lock file exists, as after any daemon ever ran: the probe opens
      # and locks it, and must let go at once.
      queue.lock
      queue.unlock
      IcingaPagerduty::Queue.new(root).daemon_running?

      expect { queue.lock }.not_to raise_error
    end
  end

  # Two daemons on one spool would deliver every event twice and race on
  # deleting it.
  describe "#lock" do
    before_each { queue.prepare }
    after_each { queue.unlock }

    it "lets a single daemon hold the spool" do
      queue.lock
      other = IcingaPagerduty::Queue.new(root)

      expect { other.lock }.to raise_error(IcingaPagerduty::SpoolLockedError, "another daemon already holds #{root}/daemon.lock")
    end

    it "frees the spool once unlocked" do
      queue.lock
      queue.unlock
      other = IcingaPagerduty::Queue.new(root)

      expect { other.lock }.not_to raise_error
      other.unlock
    end
  end

  describe "#purge_failed" do
    before_each { queue.prepare }

    it "deletes failed events older than the threshold, reason files included" do
      old = queue.push("old")
      queue.fail(old, "too old")
      recent = queue.push("recent")
      queue.fail(recent, "still recent")

      eight_days_ago = clock[0] - 8.days
      File.touch(root / "failed" / old.basename, eight_days_ago)
      File.touch(root / "failed" / "#{old.basename}.reason", eight_days_ago)

      expect(queue.purge_failed(7.days)).to eq(1)
      expect(names_in(root / "failed")).to eq([recent.basename, "#{recent.basename}.reason"])
    end
  end
end
