# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Keep the version here and in `shard.yml` in step: the `info` subcommand prints
the shard version next to the git tag precisely so a drift between the two is
visible in the field.

## [Unreleased]

### Changed

- The daemon processes the queue as soon as an event lands in it (inotify on
  Linux, FSEvents on macOS, through watch.cr) instead of up to 2 s later; the
  2 s pass stays as a safety net, and an arrival never cuts a backoff short.

## [0.1.0] - 2026-10-05

### Added

- `enqueue` subcommand: builds the PagerDuty event `pd-nagios` used to queue
  from Icinga's notification environment and writes it to the spool
  atomically, synced to disk, in an order that survives a wall clock stepped
  back.
- `daemon` subcommand: drains the spool to the PagerDuty Events API v1 in
  arrival order over one kept-alive connection. Network and TLS errors, 403
  (how the Events API v1 throttles), 408, 429, 3xx and 5xx keep the event at
  the head of the queue and back off 60 s, as pdagent did; any other 4xx moves
  it to `failed/`, as does an entry that cannot be read, and refused events are
  purged 7 days after their refusal. The daemon locks the spool: a second one
  on it refuses to start.
- `check` subcommand: an Icinga check plugin reporting whether a daemon holds
  the spool, the age of the oldest queued event and the refused events.
- `systemd-unit` subcommand: prints the daemon's systemd unit, compiled into
  the binary from `systemd/icinga-pagerduty.service`.
