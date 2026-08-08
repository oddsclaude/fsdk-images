kind: manual
description: |
  Build the ignition binary from the upstream source using the
  freedesktop-sdk Go toolchain.

# ignition is not packaged in freedesktop-sdk, so it is built here from the
# upstream source tarball. The build links against FSDK-provided system
# libraries via pkg-config: libsystemd (sd-bus/journal) and libssl.
build-depends:
  # Toolchain: go, gcc/binutils, pkg-config, tar, stripper
  - freedesktop-sdk.bst:components/go.bst
  - freedesktop-sdk.bst:components/gcc.bst
  - freedesktop-sdk.bst:components/pkg-config.bst
  - freedesktop-sdk.bst:components/tar.bst
  - freedesktop-sdk.bst:components/stripper.bst
  # C libraries ignition links against
  - freedesktop-sdk.bst:components/systemd-base.bst
  - freedesktop-sdk.bst:components/openssl.bst

depends:
  - freedesktop-sdk.bst:components/systemd.bst

variables:
  ignition-version: "2.26.0"

sources:
  - kind: remote
    url: https://codeload.github.com/coreos/ignition/tar.gz/refs/tags/v2.26.0
    ref: 4c0ff576e958bf77ee55d67871d5b85f9cd489a21e1d6050519fd983465c1d1a

config:
  build-commands:
  - |
    tar -xzf v2.26.0
    cd ignition-%{ignition-version}
    # Build from source using the FSDK Go toolchain
    export CGO_ENABLED=1
    # Unlike most Go projects, ignition's main package lives at ./internal
    # (main.go), not ./cmd/ignition - there is no cmd/ directory in this repo.
    go build -mod=vendor -ldflags "-s -w" -o ignition ./internal

  install-commands:
  - |
    install -D -m 0755 ignition-%{ignition-version}/ignition "%{install-root}%{bindir}/ignition"
