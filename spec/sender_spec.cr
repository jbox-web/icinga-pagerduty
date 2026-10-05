require "./spec_helper"

Spectator.describe IcingaPagerduty::Sender do
  let(body) { %({"service_key":"0123456789abcdef0123456789abcdef","event_type":"trigger"}) }

  it "targets the Events API v1 endpoint pdagent used" do
    expect(IcingaPagerduty::Sender::EVENTS_URL).to eq("https://events.pagerduty.com/generic/2010-04-15/create_event.json")
  end

  it "bounds connection and read to 5 s each" do
    expect(IcingaPagerduty::Sender::CONNECT_TIMEOUT).to eq(5.seconds)
    expect(IcingaPagerduty::Sender::READ_TIMEOUT).to eq(5.seconds)
  end

  context "when PagerDuty accepts the event" do
    it "posts the body once, as JSON, to the endpoint path" do
      api = FakeEventsApi.new(202)
      result = IcingaPagerduty::Sender.new(api.url).deliver(body)
      api.close

      expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Delivered)
      expect(result.message).to eq("HTTP 202")
      expect(api.requests.size).to eq(1)
      expect(api.requests[0][:path]).to eq("/generic/2010-04-15/create_event.json")
      expect(api.requests[0][:content_type]).to eq("application/json")
      expect(api.requests[0][:body]).to eq(body)
    end

    # A backlog drained after an outage must not pay one handshake per event.
    it "sends successive events over one connection" do
      api = FakeEventsApi.new(202)
      sender = IcingaPagerduty::Sender.new(api.url)
      sender.deliver(body)
      sender.deliver(body)
      sender.close
      api.close

      expect(api.requests.size).to eq(2)
      expect(api.requests[1][:remote]).to eq(api.requests[0][:remote])
    end
  end

  context "after a failed delivery" do
    it "opens a fresh connection for the next one" do
      api = FakeEventsApi.new(202, delay: 300.milliseconds)
      sender = IcingaPagerduty::Sender.new(api.url, read_timeout: 100.milliseconds)
      sender.deliver(body)
      api.delay = Time::Span.zero
      result = sender.deliver(body)
      sender.close
      api.close

      expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Delivered)
      expect(api.requests.last[:remote]).not_to eq(api.requests.first[:remote])
    end
  end

  # Throttling, timeouts, redirects and server errors say nothing against the
  # event itself: it must stay queued. 403 is how the Events API v1 throttles,
  # and pdagent retried it, as it retried any 3xx (pdagent/sendevent.py).
  {% for status in [301, 403, 408, 429, 500, 503] %}
    context "when PagerDuty answers {{status}}" do
      it "asks for a later retry" do
        api = FakeEventsApi.new({{status}})
        result = IcingaPagerduty::Sender.new(api.url).deliver(body)
        api.close

        expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Retry)
        expect(result.message).to eq(%(HTTP {{status}}: {"status":"stub"}))
      end
    end
  {% end %}

  # A bad key or a malformed event fails identically on every retry.
  {% for status in [400, 404, 422] %}
    context "when PagerDuty answers {{status}}" do
      it "reports the event as rejected" do
        api = FakeEventsApi.new({{status}})
        result = IcingaPagerduty::Sender.new(api.url).deliver(body)
        api.close

        expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Rejected)
        expect(result.message).to eq(%(HTTP {{status}}: {"status":"stub"}))
      end
    end
  {% end %}

  context "when nothing listens on the endpoint" do
    it "asks for a later retry and names the network error" do
      # Bound then released: a port nothing listens on any more.
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      server.close

      result = IcingaPagerduty::Sender.new(URI.parse("http://127.0.0.1:#{port}/x")).deliver(body)

      expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Retry)
      # The class differs by platform (a refused connect surfaces at write
      # time on macOS): both are network errors, both must be retried.
      expect(result.message).to match(/\A(Socket::ConnectError|IO::Error): /)
    end
  end

  # OpenSSL errors descend from neither IO::Error nor Socket::Error.
  context "when the TLS handshake fails" do
    it "asks for a later retry and names the TLS error" do
      api = FakeEventsApi.new(202)
      url = api.url.dup
      url.scheme = "https"
      result = IcingaPagerduty::Sender.new(url).deliver(body)
      api.close

      expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Retry)
      expect(result.message).to match(/\AOpenSSL::SSL::Error: /)
    end
  end

  # HTTP::Client reports a malformed status line with a bare Exception.
  context "when the endpoint does not speak HTTP" do
    it "asks for a later retry" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      spawn do
        while client = server.accept?
          client.gets
          client << "NOT-HTTP\r\n\r\n"
          client.close
        end
      end

      result = IcingaPagerduty::Sender.new(URI.parse("http://127.0.0.1:#{port}/x")).deliver(body)
      server.close

      expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Retry)
      expect(result.message).to eq("Exception: Invalid HTTP response")
    end
  end

  context "when PagerDuty does not answer in time" do
    # The request count is deliberately not asserted: on Crystal 1.20
    # HTTP::Client replays the POST once after a read timeout (see Sender#post).
    it "asks for a later retry" do
      api = FakeEventsApi.new(202, delay: 1.second)
      result = IcingaPagerduty::Sender.new(api.url, read_timeout: 100.milliseconds).deliver(body)
      api.close

      expect(result.outcome).to eq(IcingaPagerduty::Sender::Outcome::Retry)
      expect(result.message).to match(/\AIO::TimeoutError: /)
    end
  end
end
