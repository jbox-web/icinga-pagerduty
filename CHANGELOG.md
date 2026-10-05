# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Keep the version here and in `shard.yml` in step: the `info` subcommand prints
the shard version next to the git tag precisely so a drift between the two is
visible in the field.

## [Unreleased]

### Added

- `check` subcommand: an Icinga check plugin reporting whether a daemon holds
  the spool, the age of the oldest queued event and the refused events.
- The daemon locks the spool: a second daemon on it refuses to start.

### Fixed

- 403 (how the Events API v1 throttles), 408, 3xx and unexpected answers are
  retried, as pdagent did, instead of moving the event to `failed/`.
- TLS errors and malformed HTTP answers are retried instead of stopping the
  daemon.
- An entry that cannot be read or described no longer stops the daemon and
  blocks every event queued behind it: it is moved to `failed/`.
- Linux release binaries no longer report a `-dirty` commit.
- Refused events are kept 7 days from their refusal, not from their queueing.
- Queue order survives a wall clock stepped back.
- Queued events are synced to disk before they become visible.
- One connection serves successive deliveries.

## [0.1.0] - 2026-10-05

### Added

- `enqueue` subcommand: builds the PagerDuty event `pd-nagios` used to queue
  from Icinga's notification environment and writes it to the spool atomically.
- `daemon` subcommand: drains the spool to the PagerDuty Events API v1 in
  arrival order, backs off 60 s on transient failures, moves refused events to
  `failed/` and purges them after 7 days.
- `systemd-unit` subcommand: prints the daemon's systemd unit, compiled into
  the binary from `systemd/icinga-pagerduty.service`.
