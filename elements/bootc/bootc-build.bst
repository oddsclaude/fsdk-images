kind: manual
description: |
  Build the bootc binary from the vendored release tarballs using the
  freedesktop-sdk Rust toolchain.

# bootc is not packaged in freedesktop-sdk, so it is built here from the
# upstream release: bootc-<version>.tar.zstd (source) plus
# bootc-<version>-vendor.tar.zstd (vendored crates.io/git deps, so the build
# is fully offline). The source build links against FSDK-provided system
# libraries via pkg-config: libostree (ostree-sys), openssl, zstd, zlib, and
# libsystemd (sd-bus/sd-journal logging). See the upstream bootc.spec for the
# equivalent RPM BuildRequires.
build-depends:
  # Toolchain: cargo/rustc (FSDK ships 1.95), clang linker, gcc/binutils,
  # and the pkg-config tool.
  - freedesktop-sdk.bst:components/rust.bst
  - freedesktop-sdk.bst:components/llvm.bst
  - freedesktop-sdk.bst:components/gcc.bst
  - freedesktop-sdk.bst:components/pkg-config.bst
  # tar is needed to unpack the vendored release tarballs below; it is not
  # present in the base build sandbox on its own.
  - freedesktop-sdk.bst:components/tar.bst
  # C libraries bootc links against (each provides its pkg-config file).
  - freedesktop-sdk.bst:components/ostree.bst
  - freedesktop-sdk.bst:components/openssl.bst
  - freedesktop-sdk.bst:components/zstd.bst
  - freedesktop-sdk.bst:components/zlib.bst
  - freedesktop-sdk.bst:components/systemd-base.bst

depends:
  - freedesktop-sdk.bst:components/ostree.bst

variables:
  bootc-version: "1.16.7"

sources:
  - kind: remote
    url: https://github.com/bootc-dev/bootc/releases/download/v1.16.7/bootc-1.16.7.tar.zstd
    ref: ba9d6938e0ca2652cad0735618c2d7bef9eeba609a918ac3d881e6f07bacd089
  - kind: remote
    url: https://github.com/bootc-dev/bootc/releases/download/v1.16.7/bootc-1.16.7-vendor.tar.zstd
    ref: 9023c08dfd23b79de88c484cdacdb0bcf5a9c0b492449fe589c7614e76cec039

config:
  build-commands:
  - |
    tar --zstd -xf bootc-%{bootc-version}.tar.zstd
    tar --zstd -xf bootc-%{bootc-version}-vendor.tar.zstd
    cd bootc-%{bootc-version}
    # Point cargo at the vendored dependency tree so the build stays offline.
    cat .cargo/vendor-config.toml >> .cargo/config.toml
    # -C strip=symbols keeps the binary small for a distroless image
    # (the upstream release profile otherwise embeds debuginfo).
    RUSTFLAGS="-C strip=symbols" cargo build --release --offline --bins

  install-commands:
  - |
    install -D -m 0755 bootc-%{bootc-version}/target/release/bootc "%{install-root}%{bindir}/bootc"
    # Runtime state dirs bootc expects, matching the upstream Makefile install.
    mkdir -p "%{install-root}%{prefix}/lib/bootc/bound-images.d" \
             "%{install-root}%{prefix}/lib/bootc/kargs.d" \
             "%{install-root}%{prefix}/lib/bootc/install"
    ln -s ../../../../sysroot/ostree/bootc/storage "%{install-root}%{prefix}/lib/bootc/storage"
