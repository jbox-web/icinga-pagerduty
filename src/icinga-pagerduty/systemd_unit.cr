module IcingaPagerduty
  # The systemd unit of the daemon, read from systemd/icinga-pagerduty.service at
  # compile time. Shipping it inside the binary guarantees that a deployment
  # installs the unit written for the very binary it starts:
  # `icinga-pagerduty systemd-unit` prints it.
  SYSTEMD_UNIT = {{ read_file("#{__DIR__}/../../systemd/icinga-pagerduty.service") }}
end
