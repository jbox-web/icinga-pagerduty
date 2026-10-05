require "http/server"

# A local stand-in for the Events API: answers every request with `status` and
# records what it received.
class FakeEventsApi
  getter requests = [] of {path: String, content_type: String?, body: String, remote: String}

  def initialize(@status : Int32, @delay : Time::Span = Time::Span.zero)
    @server = HTTP::Server.new do |context|
      request = context.request
      @requests << {path: request.path, content_type: request.headers["Content-Type"]?, body: request.body.try(&.gets_to_end) || "", remote: request.remote_address.to_s}
      sleep @delay unless @delay.zero?
      context.response.status_code = @status
      context.response.print %({"status":"stub"})
    end
    @address = @server.bind_tcp("127.0.0.1", 0)
    spawn { @server.listen }
  end

  def url : URI
    URI.parse("http://127.0.0.1:#{@address.port}/generic/2010-04-15/create_event.json")
  end

  def close : Nil
    @server.close
  end
end
