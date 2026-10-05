require "./spec_helper"

# Every expected value below is written by hand from the event pd-nagios used to
# queue (pdagent-integrations 1.6.2, bin/pd-nagios): incidents opened through
# pdagent must keep acknowledging and resolving after the switch, which only
# holds if the incident_key is byte for byte the same.
Spectator.describe IcingaPagerduty::Event do
  # from_env returns nil for a skipped notification type: every example using
  # this helper expects an event, so a nil is a failure, not a value to test.
  def build(env : Hash(String, String)) : IcingaPagerduty::Event
    IcingaPagerduty::Event.from_env(env) || raise "no event built from #{env}"
  end

  let(service_env) do
    {
      "PD_OBJECT"          => "service",
      "PD_SERVICE_KEY"     => "0123456789abcdef0123456789abcdef",
      "NOTIFICATIONTYPE"   => "PROBLEM",
      "SERVICEDESC"        => "disk",
      "SERVICEDISPLAYNAME" => "Disk space",
      "HOSTNAME"           => "web1.vigilience.fr",
      "HOSTSTATE"          => "UP",
      "HOSTDISPLAYNAME"    => "web1",
      "SERVICESTATE"       => "CRITICAL",
      "SERVICEPROBLEMID"   => "2",
      "SERVICEOUTPUT"      => "DISK CRITICAL - / 97% used",
    }
  end

  let(host_env) do
    {
      "PD_OBJECT"        => "host",
      "PD_SERVICE_KEY"   => "0123456789abcdef0123456789abcdef",
      "NOTIFICATIONTYPE" => "RECOVERY",
      "HOSTNAME"         => "web1.vigilience.fr",
      "HOSTSTATE"        => "UP",
      "HOSTPROBLEMID"    => "0",
      "HOSTOUTPUT"       => "PING OK",
    }
  end

  describe ".from_env" do
    context "with a service problem" do
      subject { build(service_env) }

      it "maps PROBLEM to trigger" do
        expect(subject.event_type).to eq("trigger")
      end

      it "keys the incident on host and service, as pd-nagios did" do
        expect(subject.incident_key).to eq("event_source=service;host_name=web1.vigilience.fr;service_desc=disk")
      end

      it "describes the service, its state and its host" do
        expect(subject.description).to eq("SERVICEDESC=disk; SERVICESTATE=CRITICAL; HOSTNAME=web1.vigilience.fr")
      end

      it "carries every service macro plus pd_nagios_object as details" do
        expect(subject.details).to eq({
          "SERVICEDESC"        => "disk",
          "SERVICEDISPLAYNAME" => "Disk space",
          "HOSTNAME"           => "web1.vigilience.fr",
          "HOSTSTATE"          => "UP",
          "HOSTDISPLAYNAME"    => "web1",
          "SERVICESTATE"       => "CRITICAL",
          "SERVICEPROBLEMID"   => "2",
          "SERVICEOUTPUT"      => "DISK CRITICAL - / 97% used",
          "pd_nagios_object"   => "service",
        })
      end

      it "keeps the service key" do
        expect(subject.service_key).to eq("0123456789abcdef0123456789abcdef")
      end
    end

    context "with a host recovery" do
      subject { build(host_env) }

      it "maps RECOVERY to resolve" do
        expect(subject.event_type).to eq("resolve")
      end

      it "keys the incident on the host alone" do
        expect(subject.incident_key).to eq("event_source=host;host_name=web1.vigilience.fr")
      end

      it "describes the host and its state" do
        expect(subject.description).to eq("HOSTNAME=web1.vigilience.fr; HOSTSTATE=UP")
      end

      it "carries every host macro plus pd_nagios_object as details" do
        expect(subject.details).to eq({
          "HOSTNAME"         => "web1.vigilience.fr",
          "HOSTSTATE"        => "UP",
          "HOSTPROBLEMID"    => "0",
          "HOSTOUTPUT"       => "PING OK",
          "pd_nagios_object" => "host",
        })
      end
    end

    it "maps ACKNOWLEDGEMENT to acknowledge" do
      env = service_env.merge({"NOTIFICATIONTYPE" => "ACKNOWLEDGEMENT"})
      expect(build(env).event_type).to eq("acknowledge")
    end

    it "fills a macro Icinga left unset with an empty string" do
      env = host_env.reject("HOSTOUTPUT")
      expect(build(env).details["HOSTOUTPUT"]).to eq("")
    end

    it "truncates the description to 1024 characters, as pdagent did" do
      env = service_env.merge({"SERVICEDESC" => "x" * 2000})
      expect(build(env).description.size).to eq(1024)
    end

    # pd-nagios' argument parser only accepted these three types: anything else
    # (DOWNTIMESTART, FLAPPINGSTART, CUSTOM...) never reached PagerDuty.
    it "skips notification types PagerDuty never received" do
      %w[DOWNTIMESTART DOWNTIMEEND FLAPPINGSTART CUSTOM].each do |type|
        expect(IcingaPagerduty::Event.from_env(service_env.merge({"NOTIFICATIONTYPE" => type}))).to be_nil
      end
    end

    it "rejects an unknown object" do
      env = service_env.merge({"PD_OBJECT" => "foo"})
      expect { IcingaPagerduty::Event.from_env(env) }.to raise_error(IcingaPagerduty::ConfigurationError, %(PD_OBJECT must be "service" or "host", got "foo"))
    end

    it "rejects a missing object" do
      expect { IcingaPagerduty::Event.from_env(service_env.reject("PD_OBJECT")) }.to raise_error(IcingaPagerduty::ConfigurationError, %(PD_OBJECT must be "service" or "host", got ""))
    end

    it "rejects an empty service key" do
      env = service_env.merge({"PD_SERVICE_KEY" => ""})
      expect { IcingaPagerduty::Event.from_env(env) }.to raise_error(IcingaPagerduty::ConfigurationError, "PD_SERVICE_KEY is empty")
    end
  end

  describe "#to_json" do
    it "serialises the Events API v1 payload pdagent sent" do
      event = build(host_env)
      expect(JSON.parse(event.to_json)).to eq(JSON.parse(<<-JSON))
        {
          "service_key": "0123456789abcdef0123456789abcdef",
          "event_type": "resolve",
          "incident_key": "event_source=host;host_name=web1.vigilience.fr",
          "description": "HOSTNAME=web1.vigilience.fr; HOSTSTATE=UP",
          "client": "icinga-pagerduty",
          "details": {
            "HOSTNAME": "web1.vigilience.fr",
            "HOSTSTATE": "UP",
            "HOSTPROBLEMID": "0",
            "HOSTOUTPUT": "PING OK",
            "pd_nagios_object": "host"
          }
        }
        JSON
    end
  end
end
