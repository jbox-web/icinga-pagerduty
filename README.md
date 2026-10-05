# icinga-pagerduty

[![GitHub License](https://img.shields.io/github/license/jbox-web/icinga-pagerduty)](https://github.com/jbox-web/icinga-pagerduty/blob/master/LICENSE)
[![Build Status](https://github.com/jbox-web/icinga-pagerduty/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/icinga-pagerduty/actions/workflows/ci.yml)
[![GitHub Release](https://img.shields.io/github/v/release/jbox-web/icinga-pagerduty)](https://github.com/jbox-web/icinga-pagerduty/releases/latest)

Delivers Icinga 2 notifications to PagerDuty through a persistent local queue —
a statically linked replacement for PagerDuty's `pdagent` and its `pd-nagios`
integration.

`pdagent` bundles `six` 1.13, whose `six.moves` importer relies on
`find_module`, removed in Python 3.12: it no longer starts on Debian trixie. Its
APT repository is signed by a key bound with SHA-1, which APT refuses since
2026-02-01, and it has not been updated since 2024. This tool keeps its
architecture and its wire format, and drops the Python runtime.

## How it works

```
Icinga ──enqueue──▶ /var/spool/icinga-pagerduty/queue/ ──daemon──▶ PagerDuty Events API
                                                         │
                                                         └─refused─▶ failed/
```

- **`icinga-pagerduty enqueue`** is Icinga's `NotificationCommand`. It builds
  the event from the macros Icinga exports and writes it to the queue — a
  temporary file renamed into place, so a half-written event is never visible.
  No network access: the notification returns at once whatever the state of
  PagerDuty.
- **`icinga-pagerduty daemon`** runs under systemd and drains the queue
  **strictly in arrival order**, as soon as an event lands in it — inotify on
  Linux, FSEvents on macOS, through [watch.cr](https://github.com/jbox-web/watch.cr)
  — and every 2 s as a safety net:
  - accepted (2xx) → removed from the queue;
  - network or TLS error, 403 (how the Events API v1 throttles), 408, 429,
    5xx, 3xx or any other unexpected answer → the pass stops and the event
    stays at the head of the queue for 60 s: a resolve never overtakes its
    trigger, and nothing is lost while PagerDuty is unreachable or throttling;
  - any other 4xx → moved to `failed/` with a `.reason` file beside it, and the
    queue goes on. Refused events are purged 7 days after their refusal.

Intervals are pdagent's own (`backoff_interval_secs`, `cleanup_threshold_secs`,
`cleanup_interval_secs`), except the 10 s send interval: events go out as they
arrive, with a 2 s pass behind. An event arriving during a 60 s backoff waits
for its end, like the rest of the queue. Where the kernel refuses a file watch
(inotify's `max_user_watches` exhausted), the daemon says so in its log and
watches the queue by polling.

### The event

Field for field the event `pd-nagios` queued (pdagent-integrations 1.6.2),
posted to the Events API v1 endpoint pdagent used,
`https://events.pagerduty.com/generic/2010-04-15/create_event.json`. The
`incident_key` in particular is unchanged — `event_source=service;host_name=<host>;service_desc=<service>`
or `event_source=host;host_name=<host>` — so incidents opened through pdagent
keep acknowledging and resolving after the switch.

| Icinga notification type | PagerDuty event type |
| --- | --- |
| `PROBLEM` | `trigger` |
| `ACKNOWLEDGEMENT` | `acknowledge` |
| `RECOVERY` | `resolve` |
| anything else | not sent (`pd-nagios` refused them too) |

On Crystal 1.20, `HTTP::Client` replays a request once after any IO error, read
timeouts included: PagerDuty may then receive an event twice, which it folds
into the same incident through the `incident_key`.

## Icinga configuration

```
object NotificationCommand "notify-host-by-pagerduty" {
  import "plugin-notification-command"

  command = [ "/usr/local/bin/icinga-pagerduty", "enqueue" ]

  env = {
    PD_OBJECT        = "host"
    PD_SERVICE_KEY   = "$user.pager$"
    NOTIFICATIONTYPE = "$notification.type$"
    HOSTNAME         = "$host.name$"
    HOSTSTATE        = "$host.state$"
    HOSTPROBLEMID    = "$host.state_id$"
    HOSTOUTPUT       = "$host.output$"
  }
}
```

For services, `PD_OBJECT = "service"` and the macros `SERVICEDESC`,
`SERVICEDISPLAYNAME`, `HOSTNAME`, `HOSTSTATE`, `HOSTDISPLAYNAME`,
`SERVICESTATE`, `SERVICEPROBLEMID`, `SERVICEOUTPUT`. A macro left unset is sent
as an empty string.

`enqueue` exits 0 when the event is queued or deliberately skipped, 1 with a
message on stderr when the environment cannot describe an event or the spool is
not writable.

## Installation

The spool is shared between two users: Icinga (`nagios`) writes, the daemon
reads and deletes. Event files are created `0640` — they carry the PagerDuty
key.

```sh
useradd --system --no-create-home --shell /usr/sbin/nologin --gid nagios icinga-pagerduty
install -d -o icinga-pagerduty -g nagios -m 2770 \
  /var/spool/icinga-pagerduty /var/spool/icinga-pagerduty/queue /var/spool/icinga-pagerduty/failed
install -m 0755 icinga-pagerduty-linux-amd64 /usr/local/bin/icinga-pagerduty
```

The Linux binaries are static and need nothing installed but the CA
certificates their TLS verification reads from `/etc/ssl/certs` — the
`ca-certificates` package on Debian. Without it every delivery fails with
`certificate verify failed` and stays queued. The macOS binaries are linked
dynamically against Homebrew's OpenSSL: `brew install openssl` first.

The systemd unit, [`systemd/icinga-pagerduty.service`](systemd/icinga-pagerduty.service),
is compiled into the binary, so the unit installed always matches the binary it
starts:

```sh
icinga-pagerduty systemd-unit > /etc/systemd/system/icinga-pagerduty.service
systemctl daemon-reload
systemctl enable --now icinga-pagerduty
```

The daemon logs one line per event to stdout (journald) and stops cleanly on
`SIGTERM`, including in the middle of a 60 s backoff. It holds a lock on
`daemon.lock` at the root of the spool: a second daemon on the same spool
refuses to start.

`--spool DIR` overrides `/var/spool/icinga-pagerduty` for `enqueue`, `daemon`
and `check`.
`PAGERDUTY_EVENTS_URL` overrides the endpoint; it exists for local tests only.

## Monitoring the pipeline

Nothing else watches the tool that pages, so `icinga-pagerduty check` reports
it to Icinga as a check plugin (exit 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN):

- CRITICAL when no daemon holds the spool, or when the oldest queued event has
  waited 15 minutes (`--critical SECONDS`);
- WARNING after 5 minutes (`--warning SECONDS`), or as long as refused events
  wait in `failed/`.

```
object CheckCommand "icinga-pagerduty" {
  command = [ "/usr/local/bin/icinga-pagerduty", "check" ]
}
```

## Development

Everything goes through `mise`, never through the raw command — the tasks carry
the `depends` that generate what the compiler needs, and the timeouts that keep
a runaway linter from burning an afternoon.

| Task | What it does |
| --- | --- |
| `mise dev:deps` | `shards install` |
| `mise dev:licenses` | Assemble `licenses/` from `licenses.manifest` |
| `mise dev:build` | Development binary into `bin/icinga-pagerduty` |
| `mise dev:spec` | Specs (Spectator), after building the binary the CLI specs drive |
| `mise dev:spec-mt` | Specs, multi-threaded |
| `mise dev:format` / `dev:format-check` | `crystal tool format` |
| `mise dev:ameba` | Static analysis, bounded at 180 s |
| `mise dev:docs` | API documentation into `docs/` |
| `mise dev:clean` | Remove `bin/*` and `lib/` |
| `mise dev:docker-image` | Local multi-platform Docker image |
| `mise dev:fix-shards-command` | Work around crystal-lang/crystal#16746 (missing `shards`) |
| `mise release:deps` | `shards install --production` |
| `mise release:build` | Release binary for the host platform, plus its `.sha256` |
| `mise release:static` | Linux static binaries for amd64 and arm64, via Docker |

`icinga-pagerduty --version` prints one self-naming line, `icinga-pagerduty
info [--json]` the decomposed build provenance.

## Third-party licenses

A statically linked binary carries its dependencies' code, so it carries their
notices too: `scripts/harvest-licenses.sh` assembles them from
`licenses.manifest` and `licenses-spdx/` into `licenses/`, which
`baked_file_system` embeds at compile time. Add a `shard` line to
`licenses.manifest` for every runtime dependency added to `shard.yml`.

## Releasing

Push a tag. `.github/workflows/release_binaries.yml` creates the release, then
attaches the Linux static binaries built in Alpine and the two macOS binaries,
each with its `.sha256`.

## License

MIT — see [LICENSE](LICENSE).
