require "./queue"

module IcingaPagerduty
  # The health of the delivery pipeline, as an Icinga check plugin reports it.
  #
  # The tool that pages is the one thing nothing else watches: a daemon that
  # stopped, or a queue stuck behind PagerDuty answers, would leave Icinga
  # paging into the void. This makes both visible to Icinga itself.
  struct Check
    # The exit codes of the monitoring plugin API.
    enum Status
      Ok       = 0
      Warning  = 1
      Critical = 2
      Unknown  = 3
    end

    record Result, status : Status, message : String

    # A healthy queue is drained within a poll interval; one 60 s backoff is
    # transient. Five minutes means PagerDuty has been refusing or unreachable
    # through several backoffs.
    WARNING_AGE  = 5.minutes
    CRITICAL_AGE = 15.minutes

    def initialize(
      @queue : Queue,
      @warning : Time::Span = WARNING_AGE,
      @critical : Time::Span = CRITICAL_AGE,
      @now : Time = Time.utc,
    )
    end

    # CRITICAL when no daemon runs or the oldest queued event waited past the
    # critical age; WARNING past the warning age, or when refused events wait
    # in failed/ for someone to look at them.
    def run : Result
      return Result.new(Status::Critical, "CRITICAL - no daemon holds #{@queue.lock_path}") unless @queue.daemon_running?

      entries = @queue.entries
      refused = @queue.refused_count
      oldest = entries.first?.try { |path| @now - File.info(path).modification_time } || Time::Span.zero
      oldest = Time::Span.zero if oldest.negative?

      status =
        if oldest >= @critical
          Status::Critical
        elsif oldest >= @warning || refused > 0
          Status::Warning
        else
          Status::Ok
        end

      seconds = oldest.total_seconds.to_i
      Result.new(status, "#{status.to_s.upcase} - #{entries.size} queued, oldest #{seconds}s, #{refused} refused" \
                         " | queued=#{entries.size} oldest=#{seconds}s;#{@warning.total_seconds.to_i};#{@critical.total_seconds.to_i} refused=#{refused}")
    end
  end
end
