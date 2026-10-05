# Command line entrypoint.
#
# This file is deliberately the *only* place that parses ARGV, touches STDIN or
# calls `exit`. `src/icinga-pagerduty.cr` is a pure library and can therefore be required
# from a spec without starting the CLI — no runtime environment guard needed.
#
# The stdlib OptionParser is used on purpose: a template must not impose a CLI
# framework on every project started from it. Swap in Admiral or anything else
# here without touching the rest of the tree.
require "json"
require "option_parser"
require "watch"

require "./icinga-pagerduty"

# Build provenance, decomposed. The counterpart of `--version`, which prints the
# same facts folded into one self-naming line: that one is harvested by a fleet
# inventory, this one is read by a human chasing down which build answered.
# Every field is always printed — a line that disappears reads as a rendering
# bug, where "unknown" states plainly that the build could not know.
def print_info(json : Bool) : Nil
  fields = {
    "version" => IcingaPagerduty::VERSION,
    "commit"  => IcingaPagerduty.commit,
    "tag"     => IcingaPagerduty.git_tag,
    "built"   => IcingaPagerduty::BUILT_AT,
    "target"  => IcingaPagerduty::TARGET,
  }

  if json
    puts fields.to_json
  else
    # Widest key plus the colon, so the values line up whatever is added here.
    width = fields.keys.max_of(&.size) + 1
    fields.each { |key, value| puts "#{"#{key}:".ljust(width)} #{value}" }
  end
end

DEFAULT_SPOOL = "/var/spool/icinga-pagerduty"

# Run by Icinga as its NotificationCommand: builds the event from the macros it
# exported and queues it. No network access, so the notification returns at
# once whatever the state of PagerDuty.
def enqueue(spool : String) : Nil
  event = IcingaPagerduty::Event.from_env(ENV.to_h)
  # A notification type PagerDuty never received: nothing to do, not an error.
  return unless event

  IcingaPagerduty::Queue.new(Path[spool]).push(event.to_json)
end

def run_daemon(spool : String) : Nil
  # journald reads a pipe, where STDOUT is block-buffered by default: without
  # this, log lines would only show up once the buffer fills.
  STDOUT.flush_on_newline = true

  queue = IcingaPagerduty::Queue.new(Path[spool])
  queue.prepare
  queue.lock

  # Overridable for local tests only; production always talks to PagerDuty.
  url = URI.parse(ENV.fetch("PAGERDUTY_EVENTS_URL", IcingaPagerduty::Sender::EVENTS_URL))
  sender = IcingaPagerduty::Sender.new(url)
  daemon = IcingaPagerduty::Daemon.new(queue, ->(body : String) { sender.deliver(body) })

  {Signal::TERM, Signal::INT}.each { |signal| signal.trap { daemon.stop } }

  # An event landing in queue/ is processed at once; the periodic pass stays
  # as the safety net. Files being written start with `.`, which the filter
  # treats as hidden: only the rename into place is reported.
  filter = Watch::Filter.new([queue.queue_dir.to_s]) do |event|
    !event.kind.deleted? && event.path.ends_with?(".json")
  end
  watcher = Watch::Watcher.new(filter, coalesce: 20.milliseconds)
  watcher.on_fallback { |error| puts "no native file events (#{error.message}): watching the queue by polling" }
  watcher.on_error { |error| puts "watching the queue failed: #{error.class}: #{error.message}" }
  watching = Channel(Nil).new
  spawn { watcher.run(watching) { daemon.queued } }

  puts "#{IcingaPagerduty.version_line} started: spool #{spool}, endpoint #{url}"
  daemon.run
  watching.close
  puts "stopped"
end

# Run by Icinga as a CheckCommand. Speaks the monitoring plugin API: one status
# line, exit 0 to 3. Any error is UNKNOWN (3) — the top-level handler's exit 1
# would read as a WARNING.
def run_check(spool : String, warning : Time::Span, critical : Time::Span) : NoReturn
  result = IcingaPagerduty::Check.new(IcingaPagerduty::Queue.new(Path[spool]), warning, critical).run
  puts result.message
  exit result.status.value
rescue e : Exception
  puts "UNKNOWN - #{e.class}: #{e.message}"
  exit IcingaPagerduty::Check::Status::Unknown.value
end

# Nil until a subcommand is seen, which is what tells "no command given" from
# "a command that happens to do nothing".
command : String? = nil
json = false
spool = DEFAULT_SPOOL
warning = IcingaPagerduty::Check::WARNING_AGE
critical = IcingaPagerduty::Check::CRITICAL_AGE

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{IcingaPagerduty::NAME} [command] [options]"

  opts.on("enqueue", "Queue the event described by Icinga's environment") do
    command = "enqueue"
    opts.banner = "Usage: #{IcingaPagerduty::NAME} enqueue [options]"
    opts.on("--spool DIR", "Spool directory (default: #{DEFAULT_SPOOL})") { |dir| spool = dir }
  end

  opts.on("daemon", "Deliver queued events to PagerDuty until stopped") do
    command = "daemon"
    opts.banner = "Usage: #{IcingaPagerduty::NAME} daemon [options]"
    opts.on("--spool DIR", "Spool directory (default: #{DEFAULT_SPOOL})") { |dir| spool = dir }
  end

  opts.on("check", "Report the daemon and the queue as an Icinga check") do
    command = "check"
    opts.banner = "Usage: #{IcingaPagerduty::NAME} check [options]"
    opts.on("--spool DIR", "Spool directory (default: #{DEFAULT_SPOOL})") { |dir| spool = dir }
    opts.on("--warning SECONDS", "Age of the oldest queued event for WARNING (default: #{warning.total_seconds.to_i})") do |value|
      warning = value.to_i.seconds
    end
    opts.on("--critical SECONDS", "Age of the oldest queued event for CRITICAL (default: #{critical.total_seconds.to_i})") do |value|
      critical = value.to_i.seconds
    end
  end

  opts.on("systemd-unit", "Print the systemd unit of the daemon") do
    command = "systemd-unit"
    opts.banner = "Usage: #{IcingaPagerduty::NAME} systemd-unit"
  end

  opts.on("info", "Print version and build provenance") do
    command = "info"
    opts.banner = "Usage: #{IcingaPagerduty::NAME} info [options]"
    opts.on("--json", "Print the provenance as JSON") { json = true }
  end

  opts.on("-v", "--version", "Print the version and exit") do
    puts IcingaPagerduty.version_line
    exit 0
  end

  opts.on("-h", "--help", "Print this help and exit") do
    puts opts
    exit 0
  end

  opts.invalid_option do |flag|
    STDERR.puts "Unknown option: #{flag}"
    STDERR.puts opts
    exit 1
  end

  opts.unknown_args do |args|
    next if args.empty?
    # Options belong to a command: given before it, they arrive here.
    if args.first.starts_with?('-')
      STDERR.puts "Option before the command: #{args.first} (options go after it)"
    else
      STDERR.puts "Unknown command: #{args.first}"
    end
    STDERR.puts opts
    exit 1
  end
end

begin
  parser.parse

  case command
  when "enqueue"
    enqueue(spool)
  when "daemon"
    run_daemon(spool)
  when "check"
    run_check(spool, warning, critical)
  when "systemd-unit"
    print IcingaPagerduty::SYSTEMD_UNIT
  when "info"
    print_info(json)
  else
    # No command: the help is the only honest answer, and it goes to STDOUT
    # because the user asked for nothing wrong.
    puts parser
  end
rescue e : Exception
  # Print the class as well: `e.message` alone is a blank line whenever the
  # message is nil, which leaves the user with nothing to act on.
  STDERR.puts "#{e.class}: #{e.message}"
  exit 1
end
