kind: manual
description: |
  Build the bootupd binary from the upstream release tarballs using the
  freedesktop-sdk Rust toolchain.

# bootupd is not packaged in freedesktop-sdk, so it is built here from the
# upstream release: bootupd-<version>.tar.gz (source archive) plus
# bootupd-<version>-vendor.tar.zstd (vendored crates.io/git deps, so the build
# is fully offline). The source build links against FSDK-provided system
# libraries via pkg-config: libsystemd (sd-bus/sd-journal logging) and
# openssl. See the upstream bootupd.spec for the equivalent RPM BuildRequires.
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
  # freedesktop-sdk-stripper is used by the build-commands below to strip
  # debuginfo from the installed bootupd binary.
  - freedesktop-sdk.bst:components/stripper.bst
  # C libraries bootupd links against (each provides its pkg-config file).
  - freedesktop-sdk.bst:components/systemd-base.bst
  - freedesktop-sdk.bst:components/openssl.bst

depends:
  - freedesktop-sdk.bst:components/systemd.bst

variables:
  bootupd-version: "0.2.36"

sources:
  - kind: remote
    url: https://codeload.github.com/coreos/bootupd/tar.gz/refs/tags/v0.2.36
    ref: 95764577c05e86de8e7874c1c3a2bb2a6f8923cf2c648a957cdd668a2c466194
  - kind: remote
    url: https://github.com/coreos/bootupd/releases/download/v0.2.36/bootupd-0.2.36-vendor.tar.zstd
    ref: 56770822998ea36d54f8dee7e2d290723101d7a6eb321d9e05ad321d9e6f0b7a

config:
  build-commands:
  - |
    tar -xzf v0.2.36
    tar --zstd -xf bootupd-%{bootupd-version}-vendor.tar.zstd
    # The vendor tarball extracts a top-level vendor/ dir, but cargo expects
    # it relative to the crate root. Move it in before cd'ing there.
    mv vendor bootupd-%{bootupd-version}/vendor
    cd bootupd-%{bootupd-version}
    # Unlike bootc, this source tree ships no .cargo/vendor-config.toml to
    # cat in - .cargo/config.toml here only has a build alias, nothing
    # pointing cargo at the vendored dependency tree. Append the
    # vendored-sources config directly so the build stays offline.
    cat >> .cargo/config.toml <<'EOF'

    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor"
    EOF
    # -C strip=symbols keeps the binary small for a container image
    # (the upstream release profile otherwise embeds debuginfo).
    RUSTFLAGS="-C strip=symbols" cargo build --release --offline --bins

  install-commands:
  - |
    install -D -m 0755 bootupd-%{bootupd-version}/target/release/bootupd "%{install-root}%{bindir}/bootupd"
