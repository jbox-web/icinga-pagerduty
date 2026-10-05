require "./spec_helper"
require "file_utils"

# Drives the compiled binary, which `mise dev:spec` builds first: src/cli.cr is
# the only file that parses ARGV and picks exit codes, and nothing else
# exercises it.
# What one run of the binary returned.
record CliRun, status : Int32, stdout : String, stderr : String

Spectator.describe "icinga-pagerduty" do
  BINARY = Path[__DIR__, "..", "bin", "icinga-pagerduty"].normalize.to_s

  let(spool) do
    path = Path[Dir.tempdir, "icinga-pagerduty-cli-#{Random::Secure.hex(6)}"]
    Dir.mkdir_p(path / "queue")
    Dir.mkdir_p(path / "failed")
    path
  end

  let(host_problem) do
    {
      "PD_OBJECT"        => "host",
      "PD_SERVICE_KEY"   => "0123456789abcdef0123456789abcdef",
      "NOTIFICATIONTYPE" => "PROBLEM",
      "HOSTNAME"         => "web1",
      "HOSTSTATE"        => "DOWN",
      "HOSTPROBLEMID"    => "7",
      "HOSTOUTPUT"       => "PING CRITICAL",
    }
  end

  after_each { FileUtils.rm_rf(spool) }

  # Icinga hands the NotificationCommand nothing but the environment it
  # declares, hence clear_env.
  def run(args : Array(String), env : Hash(String, String) = {} of String => String) : CliRun
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, args, env: env, clear_env: true, output: stdout, error: stderr)
    CliRun.new(status.exit_code, stdout.to_s, stderr.to_s)
  end

  def queued : Array(String)
    Dir.children(spool / "queue").sort
  end

  it "prints the help on STDOUT and succeeds without a command" do
    result = run([] of String)

    expect(result.status).to eq(0)
    expect(result.stdout).to start_with("Usage: icinga-pagerduty [command] [options]\n")
  end

  it "prints a self-naming version line" do
    result = run(["--version"])

    expect(result.status).to eq(0)
    expect(result.stdout).to match(/\Aicinga-pagerduty \d+\.\d+\.\d+ \(.+\)\n\z/)
  end

  it "fails on an unknown command" do
    result = run(["frobnicate"])

    expect(result.status).to eq(1)
    expect(result.stderr).to start_with("Unknown command: frobnicate\n")
  end

  it "says so when an option comes before the command" do
    result = run(["--spool", "/tmp", "daemon"])

    expect(result.status).to eq(1)
    expect(result.stderr).to start_with("Option before the command: --spool (options go after it)\n")
  end

  # Exit codes of the monitoring plugin API: 0 OK, 1 WARNING, 2 CRITICAL.
  describe "check" do
    it "is critical when no daemon runs" do
      result = run(["check", "--spool", spool.to_s])

      expect(result.status).to eq(2)
      expect(result.stdout).to eq("CRITICAL - no daemon holds #{spool}/daemon.lock\n")
    end

    it "is OK while a daemon holds an empty spool" do
      held = IcingaPagerduty::Queue.new(spool)
      held.lock
      result = run(["check", "--spool", spool.to_s])
      held.unlock

      expect(result.status).to eq(0)
      expect(result.stdout).to eq("OK - 0 queued, oldest 0s, 0 refused | queued=0 oldest=0s;300;900 refused=0\n")
    end

    it "takes the age thresholds in seconds" do
      held = IcingaPagerduty::Queue.new(spool)
      held.lock
      run(["enqueue", "--spool", spool.to_s], host_problem)
      File.touch(spool / "queue" / queued[0], Time.utc - 2.minutes)
      result = run(["check", "--spool", spool.to_s, "--warning", "60", "--critical", "600"])
      held.unlock

      expect(result.status).to eq(1)
      expect(result.stdout).to start_with("WARNING - 1 queued, oldest 120s, 0 refused | ")
    end

    it "is UNKNOWN when the spool cannot be read" do
      held = IcingaPagerduty::Queue.new(spool)
      held.lock
      FileUtils.rm_rf(spool / "queue")
      result = run(["check", "--spool", spool.to_s])
      held.unlock

      expect(result.status).to eq(3)
      expect(result.stdout).to start_with("UNKNOWN - File::NotFoundError: ")
    end
  end

  describe "enqueue" do
    it "queues the event Icinga describes" do
      result = run(["enqueue", "--spool", spool.to_s], host_problem)

      expect(result.status).to eq(0)
      expect(queued.size).to eq(1)
      event = JSON.parse(File.read(spool / "queue" / queued[0]))
      expect(event["event_type"]).to eq("trigger")
      expect(event["incident_key"]).to eq("event_source=host;host_name=web1")
      expect(event["service_key"]).to eq("0123456789abcdef0123456789abcdef")
    end

    it "succeeds without queueing a type PagerDuty never received" do
      result = run(["enqueue", "--spool", spool.to_s], host_problem.merge({"NOTIFICATIONTYPE" => "CUSTOM"}))

      expect(result.status).to eq(0)
      expect(queued).to be_empty
    end

    it "fails with the reason on a misconfigured command" do
      result = run(["enqueue", "--spool", spool.to_s], host_problem.reject("PD_OBJECT"))

      expect(result.status).to eq(1)
      expect(result.stderr).to eq(%(IcingaPagerduty::ConfigurationError: PD_OBJECT must be "service" or "host", got ""\n))
      expect(queued).to be_empty
    end

    it "fails when the spool does not exist" do
      result = run(["enqueue", "--spool", (spool / "missing").to_s], host_problem)

      expect(result.status).to eq(1)
      expect(result.stderr).to start_with("File::NotFoundError: ")
    end
  end

  describe "daemon" do
    it "delivers the queue and stops cleanly on SIGTERM" do
      api = FakeEventsApi.new(202)
      run(["enqueue", "--spool", spool.to_s], host_problem)
      output = IO::Memory.new
      process = Process.new(BINARY, ["daemon", "--spool", spool.to_s],
        env: {"PAGERDUTY_EVENTS_URL" => api.url.to_s}, clear_env: true, output: output, error: output)

      deadline = Time.instant + 5.seconds
      until queued.empty? || Time.instant > deadline
        sleep 10.milliseconds
      end
      process.terminate
      status = process.wait
      api.close

      expect(status.exit_code).to eq(0)
      expect(queued).to be_empty
      expect(api.requests.size).to eq(1)
      expect(output.to_s).to contain("delivered trigger event_source=host;host_name=web1: HTTP 202\n")
      expect(output.to_s).to end_with("stopped\n")
    end

    it "refuses to start on a spool another daemon holds" do
      held = IcingaPagerduty::Queue.new(spool)
      held.lock
      result = run(["daemon", "--spool", spool.to_s], {"PAGERDUTY_EVENTS_URL" => "http://127.0.0.1:9/x"})
      held.unlock

      expect(result.status).to eq(1)
      expect(result.stderr).to eq("IcingaPagerduty::SpoolLockedError: another daemon already holds #{spool}/daemon.lock\n")
    end
  end
end
