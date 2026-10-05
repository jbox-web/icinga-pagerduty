require "json"

require "./queue"
require "./sender"

module IcingaPagerduty
  # Drains the queue towards PagerDuty, strictly in arrival order.
  #
  # A transient failure (network, throttling, server error) stops the pass and
  # leaves the event at the head of the queue: a resolve must never overtake
  # its trigger, or the incident would stay open. A refused event is moved
  # aside so that it cannot block the queue forever.
  class Daemon
    # pdagent's send_interval_secs was 10 s; a local directory scan is cheap
    # enough to poll more often and page sooner.
    POLL_INTERVAL = 2.seconds
    # pdagent's backoff_interval_secs.
    BACKOFF = 60.seconds
    # pdagent's cleanup_threshold_secs.
    FAILED_RETENTION = 7.days
    # pdagent's cleanup_interval_secs.
    PURGE_INTERVAL = 3.hours

    # `deliver` is Sender#deliver in production; a spec passes its own.
    def initialize(
      @queue : Queue,
      @deliver : String -> Sender::Result,
      @log : IO = STDOUT,
      @poll_interval : Time::Span = POLL_INTERVAL,
    )
      @stopping = false
      @waiting = false
      # Buffered: stop must never block, even when nobody is waiting yet.
      @wake = Channel(Nil).new(1)
      @arrivals = Channel(Nil).new(1)
    end

    def run : Nil
      next_purge = Time.instant
      until @stopping
        if Time.instant >= next_purge
          purge
          next_purge = Time.instant + PURGE_INTERVAL
        end

        delay = run_once
        break if @stopping

        # Sleeps `delay`, or less if stop is called in the meantime: a 60 s
        # backoff must not delay a systemd stop. Outside a backoff, an event
        # queued in the meantime starts the next pass at once; during one, it
        # waits in its buffered channel for the backoff to end.
        @waiting = true
        if delay == BACKOFF
          select
          when @wake.receive
          when timeout(delay)
          end
        else
          select
          when @wake.receive
          when @arrivals.receive
          when timeout(delay)
          end
        end
        @waiting = false
      end
    end

    # True while the daemon waits for its next pass.
    def waiting? : Bool
      @waiting
    end

    # Called when an event lands in the queue: processes it without waiting
    # for the next periodic pass. Never blocks, and arrivals coming faster than
    # passes fold into one, since a pass takes the whole queue anyway.
    def queued : Nil
      select
      when @arrivals.send(nil)
      else
      end
    end

    def stop : Nil
      @stopping = true
      select
      when @wake.send(nil)
      else
      end
    end

    # One pass over the queue. Returns how long to wait before the next one.
    #
    # No entry may raise out of here: the daemon would exit, systemd would
    # restart it onto the same head of queue, and every page behind it would
    # wait forever.
    def run_once : Time::Span
      @queue.entries.each do |path|
        return @poll_interval if @stopping

        next unless body = read(path)
        name = describe(path, body)
        result = deliver(body)

        case result.outcome
        in .delivered?
          @queue.delete(path)
          @log.puts "delivered #{name}: #{result.message}"
        in .rejected?
          @queue.fail(path, result.message)
          @log.puts "rejected #{name}: #{result.message}"
        in .retry?
          @log.puts "retry in #{BACKOFF.total_seconds.to_i}s #{name}: #{result.message}"
          return BACKOFF
        end
      end

      @poll_interval
    end

    # A failed purge only leaves old files behind: logged, never fatal.
    private def purge : Nil
      purged = @queue.purge_failed(FAILED_RETENTION)
      @log.puts "purged #{purged} refused event(s) older than #{FAILED_RETENTION.days} days" if purged > 0
    rescue error : IO::Error
      @log.puts "purge failed: #{error.class}: #{error.message}"
    end

    # Nil when the entry cannot be read. It is moved aside rather than retried:
    # an entry that fails the same way on every pass would block the queue.
    private def read(path : Path) : String?
      File.read(path)
    rescue error : IO::Error
      reason = "#{error.class}: #{error.message}"
      @queue.fail(path, reason)
      @log.puts "unreadable #{path.basename}: #{reason}"
      nil
    end

    # Whatever `deliver` raises says nothing against the event: retry later.
    private def deliver(body : String) : Sender::Result
      @deliver.call(body)
    rescue error : Exception
      Sender::Result.new(Sender::Outcome::Retry, "#{error.class}: #{error.message}")
    end

    # Event type and incident key when the body is an event, the file name
    # otherwise: the log line must identify the event either way.
    private def describe(path : Path, body : String) : String
      event = JSON.parse(body).as_h?
      type = event.try &.["event_type"]?
      key = event.try &.["incident_key"]?
      type && key ? "#{type} #{key}" : path.basename
    rescue JSON::ParseException
      path.basename
    end
  end
end
