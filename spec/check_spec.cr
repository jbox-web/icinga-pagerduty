require "./spec_helper"
require "file_utils"

Spectator.describe IcingaPagerduty::Check do
  alias Status = IcingaPagerduty::Check::Status

  let(root) do
    path = Path[Dir.tempdir, "icinga-pagerduty-check-#{Random::Secure.hex(6)}"]
    Dir.mkdir(path)
    path
  end

  let(now) { Time.utc(2026, 10, 5, 4, 0, 0) }
  let(queue) do
    q = IcingaPagerduty::Queue.new(root, clock: -> { now })
    q.prepare
    q
  end
  let(check) { IcingaPagerduty::Check.new(queue, warning: 5.minutes, critical: 15.minutes, now: now) }

  after_each do
    queue.unlock
    FileUtils.rm_rf(root)
  end

  # Queues an event that has waited *age*.
  def queued(age : Time::Span) : Path
    path = queue.push("{}")
    File.touch(path, now - age)
    path
  end

  context "when the daemon runs" do
    before_each { queue.lock }

    it "is OK on an empty queue" do
      expect(check.run).to eq(IcingaPagerduty::Check::Result.new(Status::Ok,
        "OK - 0 queued, oldest 0s, 0 refused | queued=0 oldest=0s;300;900 refused=0"))
    end

    it "is OK while the oldest event is younger than the warning age" do
      queued(30.seconds)

      expect(check.run.status).to eq(Status::Ok)
    end

    it "warns when the oldest event waited past the warning age" do
      queued(6.minutes)
      queued(10.seconds)

      expect(check.run).to eq(IcingaPagerduty::Check::Result.new(Status::Warning,
        "WARNING - 2 queued, oldest 360s, 0 refused | queued=2 oldest=360s;300;900 refused=0"))
    end

    it "is critical when the oldest event waited past the critical age" do
      queued(20.minutes)

      expect(check.run.status).to eq(Status::Critical)
    end

    it "warns while refused events wait in failed/" do
      queue.fail(queued(1.second), "HTTP 400")

      expect(check.run).to eq(IcingaPagerduty::Check::Result.new(Status::Warning,
        "WARNING - 0 queued, oldest 0s, 1 refused | queued=0 oldest=0s;300;900 refused=1"))
    end
  end

  it "is critical when no daemon holds the spool" do
    expect(check.run).to eq(IcingaPagerduty::Check::Result.new(Status::Critical,
      "CRITICAL - no daemon holds #{root}/daemon.lock"))
  end

  it "is critical once the daemon released the spool" do
    queue.lock
    queue.unlock

    expect(check.run.status).to eq(Status::Critical)
  end
end
