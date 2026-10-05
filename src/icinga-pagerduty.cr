# Library entrypoint. Pure: it parses no ARGV, touches no STDIN and never calls
# `exit`, so a spec can require it without starting the CLI. Everything the
# command line needs lives in src/cli.cr.
require "./icinga-pagerduty/version"
require "./icinga-pagerduty/licenses"
require "./icinga-pagerduty/event"
require "./icinga-pagerduty/sender"
require "./icinga-pagerduty/queue"
require "./icinga-pagerduty/daemon"
require "./icinga-pagerduty/check"
require "./icinga-pagerduty/systemd_unit"
