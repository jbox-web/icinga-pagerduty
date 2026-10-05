###########
# CRYSTAL #
###########

FROM alpine:3.24 AS crystal

RUN apk add --update --no-cache \
  make \
  crystal=~1.20 \
  shards \
  bash \
  gc-dev \
  gc-static \
  git \
  libxml2-dev \
  libxml2-static \
  openssl-dev \
  openssl-libs-static \
  gmp-dev \
  gmp-static \
  pcre2-dev \
  pcre2-static \
  xz-dev \
  xz-static \
  yaml-dev \
  yaml-static \
  zlib-dev \
  zlib-static

#########
# BUILD #
#########

FROM crystal AS build-binary-file

# Fetch platforms variables from ARGS
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

# Export them to build binary files with the right name: icinga-pagerduty-linux-amd64
ENV \
  TARGETPLATFORM=${TARGETPLATFORM} \
  TARGETOS=${TARGETOS} \
  TARGETARCH=${TARGETARCH} \
  TARGETVARIANT=${TARGETVARIANT}

# Set build environment
WORKDIR /build
# The whole checkout, .git included, minus what .dockerignore lists — the same
# files git ignores. Copying a subset made `git status` inside the build see
# every file left out as deleted, and version.cr then stamped every release
# binary `-dirty`. It also brings what the compiler reads at macro time:
# systemd/ for the embedded unit, and licenses.manifest, licenses-spdx/ and
# LICENSE, from which the `licenses` target assembles the baked licenses/.
COPY . /build/
RUN mkdir -p /build/bin

# Build the binary. Makefile.release is named rather than renamed to Makefile,
# which git would also have reported as a change.
RUN make -f Makefile.release release

# Extract binary from Docker image
FROM scratch AS binary-file
ARG TARGETOS
ARG TARGETARCH
COPY --from=build-binary-file /build/bin/icinga-pagerduty-${TARGETOS}-${TARGETARCH} /

###########
# RUNTIME #
###########

# Build distroless images \o/
FROM gcr.io/distroless/static-debian12 AS docker-image

# Fetch platforms variables from ARGS
ARG TARGETOS
ARG TARGETARCH

# Grab icinga-pagerduty binary from **binary-file** step and inject it in the final image
COPY --from=build-binary-file /build/bin/icinga-pagerduty-${TARGETOS}-${TARGETARCH} /usr/bin/icinga-pagerduty

# Set runtime environment
USER nonroot
ENV USER=nonroot
ENV HOME=/home/nonroot
WORKDIR /home/nonroot
ENTRYPOINT ["icinga-pagerduty"]
