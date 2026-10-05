require "http/client"
require "uri"

module IcingaPagerduty
  # Posts one serialised event to the PagerDuty Events API and says what to do
  # with it next. Retrying belongs to the daemon, which keeps the event queued.
  class Sender
    # The endpoint pdagent used (pdagent/constants.py EVENTS_API_BASE).
    EVENTS_URL = "https://events.pagerduty.com/generic/2010-04-15/create_event.json"

    CONNECT_TIMEOUT = 5.seconds
    READ_TIMEOUT    = 5.seconds

    # Longest response body kept in a message: enough for PagerDuty's error
    # JSON, short enough for one journal line.
    MAX_BODY_IN_MESSAGE = 500

    enum Outcome
      # PagerDuty accepted the event: it can leave the queue.
      Delivered
      # Network error, throttling, server error or unexpected answer: try
      # again later.
      Retry
      # A 4xx that blames the event: it is refused and always will be.
      Rejected
    end

    record Result, outcome : Outcome, message : String

    # 4xx answers that say nothing against the event itself. The Events API v1
    # throttles with 403, which pdagent retried and never counted against the
    # event (pdagent/sendevent.py); 408 and 429 are transient by definition.
    TRANSIENT_CLIENT_ERRORS = {403, 408, 429}

    def initialize(
      @url : URI = URI.parse(EVENTS_URL),
      @connect_timeout : Time::Span = CONNECT_TIMEOUT,
      @read_timeout : Time::Span = READ_TIMEOUT,
    )
      @client = nil.as(HTTP::Client?)
    end

    def deliver(body : String) : Result
      response = post(body)
    rescue error : Exception
      # Not only IO::Error and Socket::Error: a failed TLS handshake raises an
      # OpenSSL::SSL::Error and a malformed answer a bare Exception, and none of
      # them says anything against the event.
      Result.new(Outcome::Retry, "#{error.class}: #{error.message}")
    else
      status = response.status_code
      if response.success?
        Result.new(Outcome::Delivered, "HTTP #{status}")
      else
        message = "HTTP #{status}: #{response.body[0, MAX_BODY_IN_MESSAGE]}"
        Result.new(refused?(status) ? Outcome::Rejected : Outcome::Retry, message)
      end
    end

    # Only a 4xx blames the event. Everything else is retried, as pdagent did:
    # 5xx, and also 3xx or any status outside the known classes — moving the
    # whole queue aside because PagerDuty answered something unexpected would
    # lose every page at once.
    private def refused?(status : Int32) : Bool
      400 <= status < 500 && !TRANSIENT_CLIENT_ERRORS.includes?(status)
    end

    # Drops the kept-alive connection, if any.
    def close : Nil
      @client.try &.close
      @client = nil
    end

    # One keep-alive connection serves every delivery, so a backlog drained
    # after an outage pays one TCP and TLS handshake rather than one per event.
    # After any error the connection is dropped: its state is unknown, and the
    # next delivery opens a fresh one.
    #
    # Known and accepted: on Crystal 1.20 (Alpine 3.24, which builds the
    # released binaries) HTTP::Client#exec replays the request once after any
    # IO error, read timeouts included, even on a fresh connection. PagerDuty
    # then receives the event twice, which it folds into the same incident
    # through the incident_key, and one attempt lasts up to twice the timeouts.
    # Crystal 1.21 only replays on a reused, reset connection — which is also
    # what recovers a kept-alive connection PagerDuty closed while idle.
    private def post(body : String) : HTTP::Client::Response
      client = @client ||= connect
      client.post(@url.request_target, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body)
    rescue error
      close
      raise error
    end

    private def connect : HTTP::Client
      client = HTTP::Client.new(@url)
      client.connect_timeout = @connect_timeout
      client.read_timeout = @read_timeout
      client
    end
  end
end
