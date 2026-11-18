# Project rules

This repository is `icinga-pagerduty`, instantiated from the Crystal application
template (`PROJECTS/CRYSTAL/JBOX/TEMPLATE`). The sections below are the
template's rules and still apply; README.md describes what the tool does.

## Run tasks through mise, never the raw command

`mise dev:spec`, not `crystal spec`. `mise dev:ameba`, not `ameba`.

The tasks are not aliases. They carry the `depends` that generate what the
compiler needs — `licenses/` above all, which `baked_file_system` reads at macro
time — and the bounds that keep a runaway process from burning hours. Locally
the generated artifacts are always lying around from an earlier build, which is
exactly what makes a missing `depends` invisible until a bare checkout in CI.

`ameba` (a mise tool since 1.7.0, no longer a shard) in particular is never to be called directly: `dev:ameba` carries
`timeout = "180s"`, because ameba can spin at 100% CPU indefinitely on some
inputs. That is mise's own task `timeout`, not GNU coreutils — it works the same
on macOS, which ships no `timeout`, and needs mise 2026.10.2 or later
(`min_version` in `mise.toml`).

## The canonical templates live outside this repository

`mise.toml`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`,
`.crystalreleaser.yml`, `Brewfile`, `scripts/harvest-licenses.sh`,
`scripts/kcov.css` and `src/icinga-pagerduty/version.cr` are copies of the
canonical templates in `~/.claude/templates/crystal/` (`mise.toml`,
`ci-binary.yml`, `release.yml`, `crystalreleaser.yml`, `Brewfile`,
`harvest-licenses.sh`, `kcov.css`, `version.cr`).

When one of them needs to change: **fix the canonical template first**, then
copy it back here. A fix landed only in this repository is a fix the next
project will not get. The intentional divergences, and there are only these:

- `mise.toml` — `APP_NAME`, and `SOURCE_FILE = "src/cli.cr"` because the library
  file has no `main`; `dev:build` in the `depends` of `dev:spec`,
  `dev:spec-mt` and `dev:coverage`, because `spec/cli_spec.cr` drives the
  compiled binary; no
  `dev:docker-image`, the project builds no image.
- `.crystalreleaser.yml` — the project name only.
- `Brewfile` — `gettext` removed (nothing calls `envsubst`); `openssl@4` and
  `cask 'docker'` added, which `mise release:static` needs on a Mac.
- `version.cr` — the trailing "BINARY ONLY — wiring, for reference" comment
  block is dropped, the wiring itself being realised in `src/cli.cr`.

Releases are built by crystalreleaser: `mise release:static` rehearses them
into `dist/`, a `v*` tag runs `.github/workflows/release.yml`, which publishes
`icinga-pagerduty-<os>-<arch>` and its `.sha256`. The linux binaries are built
in the Alpine image crystalreleaser generates, with the whole checkout mounted:
anything the build leaves behind that git does not ignore would make
`version.cr` stamp the binary `-dirty`.

## Licenses are not optional decoration

Add a `shard` line to `licenses.manifest` for every runtime dependency added to
`shard.yml`. Nothing checks it automatically, and a notice missing from a
redistributed static binary is precisely the fault the machinery exists to
prevent. A license file named in the manifest but absent from disk is a hard
error by design — never soften it to a warning.

`licenses/` is generated and gitignored. `licenses.manifest`,
`licenses-spdx/` and `licenses-upstream/` are tracked and are what the project
owns. The manifest follows the link line of the static binary, recorded in its
header: check it again when a stdlib module is added.

## Before claiming anything works

`mise dev:format-check`, `mise dev:ameba`, `mise dev:spec`, `mise dev:build`,
`mise dev:docs` — with their output. A pager that merely looks like it works is
worse than none: nobody watches it until the night it stays silent.
