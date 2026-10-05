require "json"

module IcingaPagerduty
  # Raised when the environment Icinga passed cannot describe an event: a
  # misconfigured NotificationCommand, never a transient condition.
  class ConfigurationError < Exception
  end

  # One PagerDuty Events API v1 event, built from the environment of an Icinga
  # NotificationCommand.
  #
  # It reproduces, field for field, the event pd-nagios queued into pdagent
  # (pdagent-integrations 1.6.2): same incident_key, description and details.
  # Incidents opened through pdagent therefore keep acknowledging and resolving
  # once this tool replaces it.
  struct Event
    # Icinga notification types forwarded, and their PagerDuty event type. Any
    # other type was rejected by pd-nagios' argument parser and never reached
    # PagerDuty.
    EVENT_TYPES = {
      "PROBLEM"         => "trigger",
      "ACKNOWLEDGEMENT" => "acknowledge",
      "RECOVERY"        => "resolve",
    }

    # Macros sent as details for each object, in the order Icinga passes them.
    DETAIL_KEYS = {
      "service" => %w[SERVICEDESC SERVICEDISPLAYNAME HOSTNAME HOSTSTATE HOSTDISPLAYNAME SERVICESTATE SERVICEPROBLEMID SERVICEOUTPUT],
      "host"    => %w[HOSTNAME HOSTSTATE HOSTPROBLEMID HOSTOUTPUT],
    }

    # Details that make up the description (pd-nagios _event_description).
    DESCRIPTION_KEYS = {
      "service" => %w[SERVICEDESC SERVICESTATE HOSTNAME],
      "host"    => %w[HOSTNAME HOSTSTATE],
    }

    # pdagent truncated the description to this length (MAX_DESCRIPTION_LEN).
    MAX_DESCRIPTION_SIZE = 1024

    CLIENT = "icinga-pagerduty"

    getter service_key : String
    getter event_type : String
    getter incident_key : String
    getter description : String
    getter details : Hash(String, String)

    def initialize(@service_key, @event_type, @incident_key, @description, @details)
    end

    # Returns nil for a notification type PagerDuty never received, so that the
    # caller can exit successfully without sending anything.
    def self.from_env(env : Hash(String, String)) : Event?
      object = env.fetch("PD_OBJECT", "")
      detail_keys = DETAIL_KEYS[object]? || raise ConfigurationError.new(%(PD_OBJECT must be "service" or "host", got #{object.inspect}))

      service_key = env.fetch("PD_SERVICE_KEY", "")
      raise ConfigurationError.new("PD_SERVICE_KEY is empty") if service_key.empty?

      event_type = EVENT_TYPES[env.fetch("NOTIFICATIONTYPE", "")]?
      return unless event_type

      # An unset macro becomes an empty string, as Icinga renders it.
      details = detail_keys.to_h { |key| {key, env.fetch(key, "")} }
      details["pd_nagios_object"] = object

      description = DESCRIPTION_KEYS[object].join("; ") { |key| "#{key}=#{details[key]}" }

      new(service_key, event_type, incident_key(object, details), description[0, MAX_DESCRIPTION_SIZE], details)
    end

    private def self.incident_key(object : String, details : Hash(String, String)) : String
      if object == "service"
        "event_source=service;host_name=#{details["HOSTNAME"]};service_desc=#{details["SERVICEDESC"]}"
      else
        "event_source=host;host_name=#{details["HOSTNAME"]}"
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "service_key", service_key
        json.field "event_type", event_type
        json.field "incident_key", incident_key
        json.field "description", description
        json.field "client", CLIENT
        json.field "details", details
      end
    end
  end
end
