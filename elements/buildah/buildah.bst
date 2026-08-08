kind: manual
description: |
  Build the buildah binary from the upstream source using the
  freedesktop-sdk Go toolchain.

# buildah is not packaged in freedesktop-sdk, so it is built here from the
# upstream source tarball. The build links against FSDK-provided system
# libraries via pkg-config: libcontainers-image, libcontainers-storage,
# gpgme, and libseccomp.
build-depends:
  # Toolchain: go, gcc/binutils, pkg-config, tar, stripper
  - freedesktop-sdk.bst:components/go.bst
  - freedesktop-sdk.bst:components/gcc.bst
  - freedesktop-sdk.bst:components/pkg-config.bst
  - freedesktop-sdk.bst:components/tar.bst
  - freedesktop-sdk.bst:components/stripper.bst
  # C libraries buildah links against
  - freedesktop-sdk.bst:components/containers-common.bst
  - freedesktop-sdk.bst:components/gpgme.bst
  - freedesktop-sdk.bst:components/libseccomp.bst

depends:
  - freedesktop-sdk.bst:components/containers-common.bst

variables:
  buildah-version: "1.45.0"

sources:
  - kind: remote
    url: https://github.com/podman-container-tools/buildah/archive/refs/tags/v1.45.0.tar.gz
    ref: d2bc03332c9f6ad5fcc210c68ad3190fe11d358214c88fb12a233f5045d5eddd

config:
  build-commands:
  - |
    # tar already handles gzip decompression natively (-z); no need for a
    # separate python3 unzip step, which also silently requires python3 as
    # an undeclared build dependency.
    tar -xzf v1.45.0.tar.gz
    cd buildah-%{buildah-version}
    # Build from source using the FSDK Go toolchain.
    # The btrfs storage driver needs btrfs/ioctl.h; if unavailable,
    # exclude it with the standard buildah tag.
    BUILD_TAGS="exclude_graphdriver_btrfs"
    export CGO_ENABLED=1
    go build -mod=vendor -tags="${BUILD_TAGS}" -ldflags "-s -w" -o buildah ./cmd/buildah

  install-commands:
  - |
    install -D -m 0755 buildah-%{buildah-version}/buildah "%{install-root}%{bindir}/buildah"
