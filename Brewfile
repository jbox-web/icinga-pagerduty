# frozen_string_literal: true

# Brewfile — the macOS side of a Crystal project's toolchain.
#
#   brew bundle              install everything listed here
#   brew bundle check        report what is missing, install nothing
#
# WHAT BELONGS HERE, AND WHAT DOES NOT
#   Not the compiler: mise owns Crystal and shards, pinned in mise.toml, so a
#   `brew install crystal` would give the machine a second one and let the two
#   disagree. What belongs here is what mise cannot install and the tasks shell
#   out to — plus mise itself, which has to come from somewhere.
#
#   Nor the libraries Crystal links against (libyaml, pcre2, openssl, gmp…):
#   the mise-installed toolchain brings what it needs, and listing them here
#   invites a version skew that is painful to diagnose. Add one only when a
#   link actually fails without it.

# The Apple bash is 3.2, from 2007: no associative arrays, no `declare -n`,
# none of what a script written this decade assumes. Either install a modern
# one or write every script against 3.2 — deliberately, and in a comment.
brew 'bash'

# The task runner and the toolchain it pins. Everything else in the project is
# driven through `mise <task>`, never through the raw command.
brew 'mise'

# --- From here down: keep only what this project actually uses -------------

# Example of a project-specific entry: a service the specs or the benchmark
# talk to. Replace or remove.
# brew 'ollama'

# Docker is a cask, not a formula. This template ships binaries, so its release
# path goes through `docker buildx bake` (release:static, dev:docker-image) and
# Docker is required, not optional. Remove it if the project stops shipping
# Linux static binaries.
cask 'docker'
