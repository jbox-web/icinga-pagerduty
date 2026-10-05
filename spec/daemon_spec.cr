require "./spec_helper"
require "file_utils"

Spectator.describe IcingaPagerduty::Daemon do
  alias Outcome = IcingaPagerduty::Sender::Outcome
  alias Result = IcingaPagerduty::Sender::Result

  let(root) do
    path = Path[Dir.tempdir, "icinga-pagerduty-spec-#{Random::Secure.hex(6)}"]
    Dir.mkdir(path)
    path
  end

  let(queue) do
    q = IcingaPagerduty::Queue.new(root)
    q.prepare
    q
  end

  let(log) { IO::Memory.new }

  # Bodies the daemon handed to PagerDuty, and the answers it gets, in order
  # (the last one repeats).
  let(sent) { [] of String }
  let(answers) { [Result.new(Outcome::Delivered, "HTTP 202")] }
  let(deliver) do
    ->(body : String) do
      sent << body
      answers[{sent.size, answers.size}.min - 1]
    end
  end

  let(daemon) { IcingaPagerduty::Daemon.new(queue, deliver, log: log, poll_interval: 10.milliseconds) }

  after_each { FileUtils.rm_rf(root) }

  # Waits for a condition the daemon fiber brings about, bounded so that a
  # regression fails the example instead of hanging the suite.
  def wait_until(limit : Time::Span = 2.seconds, &) : Nil
    deadline = Time.instant + limit
    until yield
      raise "condition not met within #{limit}" if Time.instant > deadline
      sleep 5.milliseconds
    end
  end

  def event(type : String, host : String) : String
    %({"event_type":"#{type}","incident_key":"event_source=host;host_name=#{host}"})
  end

  it "polls every 2 s and backs off 60 s, as pdagent's send interval and backoff" do
    expect(IcingaPagerduty::Daemon::POLL_INTERVAL).to eq(2.seconds)
    expect(IcingaPagerduty::Daemon::BACKOFF).to eq(60.seconds)
  end

  it "keeps refused events 7 days, as pdagent's cleanup threshold" do
    expect(IcingaPagerduty::Daemon::FAILED_RETENTION).to eq(7.days)
  end

  describe "#run_once" do
    it "sends nothing when the queue is empty" do
      expect(daemon.run_once).to eq(10.milliseconds)
      expect(sent).to be_empty
    end

    it "delivers every queued event in arrival order and empties the queue" do
      queue.push(event("trigger", "web1"))
      queue.push(event("resolve", "web1"))

      expect(daemon.run_once).to eq(10.milliseconds)
      expect(sent).to eq([event("trigger", "web1"), event("resolve", "web1")])
      expect(queue.entries).to be_empty
      expect(log.to_s).to eq(<<-LOG)
        delivered trigger event_source=host;host_name=web1: HTTP 202
        delivered resolve event_source=host;host_name=web1: HTTP 202

        LOG
    end

    # A resolve overtaking its trigger would leave the incident open: on a
    # transient failure the whole queue waits, head first.
    context "when PagerDuty asks for a retry" do
      let(answers) { [Result.new(Outcome::Retry, "HTTP 503: unavailable")] }

      it "keeps the event at the head of the queue and backs off" do
        first = queue.push(event("trigger", "web1"))
        second = queue.push(event("resolve", "web1"))

        expect(daemon.run_once).to eq(60.seconds)
        expect(sent).to eq([event("trigger", "web1")])
        expect(queue.entries).to eq([first, second])
        expect(log.to_s).to eq("retry in 60s trigger event_source=host;host_name=web1: HTTP 503: unavailable\n")
      end
    end

    context "when PagerDuty rejects an event" do
      let(answers) do
        [Result.new(Outcome::Rejected, "HTTP 400: invalid service key"), Result.new(Outcome::Delivered, "HTTP 202")]
      end

      it "moves it to failed and goes on with the next one" do
        rejected = queue.push(event("trigger", "web1"))
        queue.push(event("trigger", "web2"))

        expect(daemon.run_once).to eq(10.milliseconds)
        expect(sent.size).to eq(2)
        expect(queue.entries).to be_empty
        expect(Dir.children(root / "failed").sort).to eq([rejected.basename, "#{rejected.basename}.reason"])
        expect(log.to_s).to eq(<<-LOG)
          rejected trigger event_source=host;host_name=web1: HTTP 400: invalid service key
          delivered trigger event_source=host;host_name=web2: HTTP 202

          LOG
      end
    end

    it "still names an event whose body is not JSON" do
      path = queue.push("not json")
      daemon.run_once

      expect(log.to_s).to eq("delivered #{path.basename}: HTTP 202\n")
    end

    # Whatever one entry does, it must neither stop the daemon nor block the
    # entries queued behind it: an entry failing the same way on every pass
    # would otherwise silence every page after it.
    it "goes on past an event whose body is JSON but not an object" do
      odd = queue.push("[1]")
      queue.push(event("trigger", "web1"))

      expect(daemon.run_once).to eq(10.milliseconds)
      expect(sent).to eq(["[1]", event("trigger", "web1")])
      expect(log.to_s).to eq(<<-LOG)
        delivered #{odd.basename}: HTTP 202
        delivered trigger event_source=host;host_name=web1: HTTP 202

        LOG
    end

    it "moves an unreadable entry aside and goes on with the next one" do
      # A directory is unreadable for root too, so this holds in the nightly
      # container where the suite runs as root.
      unreadable = queue.queue_dir / "00000000000000000000-000000-1.json"
      Dir.mkdir(unreadable)
      queue.push(event("trigger", "web1"))

      expect(daemon.run_once).to eq(10.milliseconds)
      expect(sent).to eq([event("trigger", "web1")])
      expect(queue.entries).to be_empty
      expect(Dir.children(root / "failed").sort).to eq([unreadable.basename, "#{unreadable.basename}.reason"])
      expect(File.read(root / "failed" / "#{unreadable.basename}.reason")).to start_with("IO::Error: ")
      expect(log.to_s).to start_with("unreadable #{unreadable.basename}: IO::Error: ")
    end

    context "when delivering raises" do
      let(deliver) { ->(_body : String) : Result { raise "boom" } }

      it "keeps the event at the head of the queue and backs off" do
        first = queue.push(event("trigger", "web1"))

        expect(daemon.run_once).to eq(60.seconds)
        expect(queue.entries).to eq([first])
        expect(log.to_s).to eq("retry in 60s trigger event_source=host;host_name=web1: Exception: boom\n")
      end
    end
  end

  # An hour between passes: only an arrival can start one within the example.
  describe "#queued" do
    let(daemon) { IcingaPagerduty::Daemon.new(queue, deliver, log: log, poll_interval: 1.hour) }

    it "processes the queue as soon as an event arrives" do
      done = Channel(Nil).new
      spawn { daemon.run; done.send(nil) }
      wait_until { daemon.waiting? }

      queue.push(event("trigger", "web1"))
      daemon.queued

      wait_until(limit: 1.second) { !sent.empty? }
      daemon.stop
      done.receive
      expect(sent).to eq([event("trigger", "web1")])
    end

    context "during a backoff" do
      let(answers) { [Result.new(Outcome::Retry, "HTTP 503")] }

      # The backoff spares PagerDuty while it fails: an arrival must not end
      # it early, or a burst of notifications would hammer it.
      it "processes nothing before the backoff ends" do
        queue.push(event("trigger", "web1"))
        done = Channel(Nil).new
        spawn { daemon.run; done.send(nil) }
        wait_until { log.to_s.includes?("retry in 60s") }

        queue.push(event("resolve", "web1"))
        daemon.queued
        sleep 100.milliseconds
        daemon.stop
        done.receive

        expect(sent).to eq([event("trigger", "web1")])
      end
    end
  end

  describe "#run" do
    it "delivers what is queued until stopped" do
      queue.push(event("trigger", "web1"))
      done = Channel(Nil).new
      spawn { daemon.run; done.send(nil) }

      wait_until { !sent.empty? }
      daemon.stop

      select
      when done.receive
      when timeout(1.second)
        fail "the daemon did not stop within 1 s"
      end
      expect(sent).to eq([event("trigger", "web1")])
    end

    it "wakes up from a backoff as soon as it is stopped" do
      slow = IcingaPagerduty::Daemon.new(queue, ->(_body : String) { Result.new(Outcome::Retry, "HTTP 503") }, log: log, poll_interval: 10.milliseconds)
      queue.push(event("trigger", "web1"))
      done = Channel(Nil).new
      spawn { slow.run; done.send(nil) }

      wait_until { log.to_s.includes?("retry in 60s") }
      slow.stop

      select
      when done.receive
      when timeout(1.second)
        fail "the daemon slept through its 60 s backoff instead of stopping"
      end
    end

    it "purges refused events older than the retention when it starts" do
      old = queue.push("old")
      queue.fail(old, "refused")
      File.touch(root / "failed" / old.basename, Time.utc - 8.days)
      File.touch(root / "failed" / "#{old.basename}.reason", Time.utc - 8.days)

      done = Channel(Nil).new
      spawn { daemon.run; done.send(nil) }

      wait_until { Dir.children(root / "failed").empty? }
      daemon.stop
      done.receive

      expect(Dir.children(root / "failed")).to be_empty
    end

    it "logs a purge that fails and keeps delivering" do
      # A directory cannot be deleted as a file: the purge fails on it.
      stuck = queue.failed_dir / "stuck.json"
      Dir.mkdir(stuck)
      File.touch(stuck, Time.utc - 8.days)
      queue.push(event("trigger", "web1"))
      done = Channel(Nil).new
      spawn { daemon.run; done.send(nil) }

      wait_until { !sent.empty? }
      daemon.stop
      done.receive

      expect(log.to_s).to start_with("purge failed: File::Error: ")
      expect(sent).to eq([event("trigger", "web1")])
    end
  end
end
